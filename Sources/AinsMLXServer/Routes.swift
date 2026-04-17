import Vapor
import Foundation
import MLXLMCommon

private let apiJSONEncoder = JSONEncoder()

private func isVerboseRequestLoggingEnabled() -> Bool {
    let value = ProcessInfo.processInfo.environment["DEBUG_OPENAI_MESSAGES"]?.lowercased()
    return value == "1" || value == "true" || value == "yes"
}

private func makeJSONResponse<T: Encodable>(_ value: T, status: HTTPResponseStatus = .ok) throws -> Response {
    let data = try apiJSONEncoder.encode(value)
    let response = Response(status: status)
    response.headers.replaceOrAdd(name: .contentType, value: "application/json; charset=utf-8")
    response.body = .init(string: String(decoding: data, as: UTF8.self))
    return response
}

private func resolveRequestedTools(_ tools: [RawTool]?, toolChoice: ToolChoice?) -> [RawTool]? {
    guard let tools, !tools.isEmpty else { return nil }

    switch toolChoice?.mode {
    case "none":
        return nil
    case "function":
        guard let functionName = toolChoice?.functionName else {
            return tools
        }
        let filtered = tools.filter { $0.function.name == functionName }
        return filtered.isEmpty ? nil : filtered
    default:
        return tools
    }
}

private func makeStreamChunk(
    id: String,
    created: Int,
    model: String,
    delta: ChunkDelta,
    finishReason: String? = nil
) -> ChatCompletionChunk {
    ChatCompletionChunk(
        id: id,
        created: created,
        model: model,
        choices: [ChunkChoice(index: 0, delta: delta, finish_reason: finishReason)]
    )
}

private func writeSSEChunk(_ chunk: ChatCompletionChunk, writer: BodyStreamWriter) async throws {
    let json = try String(decoding: apiJSONEncoder.encode(chunk), as: UTF8.self)
    try await writer.write(.buffer(.init(string: "data: \(json)\n\n"))).get()
}

private func writeSSEDone(writer: BodyStreamWriter) async throws {
    try await writer.write(.buffer(.init(string: "data: [DONE]\n\n"))).get()
    try await writer.write(.end).get()
}

func configureRoutes(
    on app: Application,
    config: ServerConfig,
    modelRuntime: ModelRuntime
) {
    app.get { req async throws -> Response in
        if let embeddedResponse = EmbeddedAssets.serve(req) {
            return embeddedResponse
        }

        return EmbeddedAssets.notFoundResponse()
    }

    app.get("**") { req async throws -> Response in
        if let embeddedResponse = EmbeddedAssets.serve(req) {
            return embeddedResponse
        }

        return EmbeddedAssets.notFoundResponse()
    }

    app.post("v1", "chat", "completions") { req async throws -> Response in
        let input: ChatCompletionRequest
        do {
            input = try req.content.decode(ChatCompletionRequest.self)
        } catch {
            print("❌ [OpenAI API] Decoding failed: \(error)")
            throw Abort(.badRequest, reason: "Invalid request format: \(error.localizedDescription)")
        }

        let requestedTools = resolveRequestedTools(input.tools, toolChoice: input.tool_choice)
        print("📝 [OpenAI API] Request Received (Model: \(input.model ?? "default"), Messages: \(input.messages.count), Stream: \(input.stream ?? false), Tools: \(requestedTools?.count ?? 0))")
        if isVerboseRequestLoggingEnabled() {
            for (index, message) in input.messages.enumerated() {
                print("🧾 [OpenAI API] Message[\(index)] \(message.debugSummary)")
            }
        }

        if input.stream == true {
            let requestId = "chatcmpl-\(UUID().uuidString.lowercased())"
            let responseModel = input.model ?? config.model.path
            let created = Int(Date().timeIntervalSince1970)

            let response = Response(status: .ok)
            response.headers.replaceOrAdd(name: .contentType, value: "text/event-stream")
            response.headers.replaceOrAdd(name: .cacheControl, value: "no-cache")
            response.headers.replaceOrAdd(name: .connection, value: "keep-alive")
            response.headers.replaceOrAdd(name: .transferEncoding, value: "chunked")
            response.headers.replaceOrAdd(name: "X-Accel-Buffering", value: "no")

            response.body = .init(stream: { writer in
                Task {
                    do {
                        if let requestedTools, !requestedTools.isEmpty {
                            let generated = try await modelRuntime.generate(
                                messages: input.messages,
                                temperature: input.temperature,
                                maxTokens: input.max_tokens,
                                tools: requestedTools
                            )

                            try await writeSSEChunk(
                                makeStreamChunk(
                                    id: requestId,
                                    created: created,
                                    model: responseModel,
                                    delta: .assistantRole
                                ),
                                writer: writer
                            )

                            if !generated.toolCalls.isEmpty {
                                try await writeSSEChunk(
                                    makeStreamChunk(
                                        id: requestId,
                                        created: created,
                                        model: responseModel,
                                        delta: ChunkDelta(role: nil, content: nil, tool_calls: generated.toolCalls)
                                    ),
                                    writer: writer
                                )
                            } else if !generated.text.isEmpty {
                                try await writeSSEChunk(
                                    makeStreamChunk(
                                        id: requestId,
                                        created: created,
                                        model: responseModel,
                                        delta: ChunkDelta(role: nil, content: generated.text, tool_calls: nil)
                                    ),
                                    writer: writer
                                )
                            }

                            try await writeSSEChunk(
                                makeStreamChunk(
                                    id: requestId,
                                    created: created,
                                    model: responseModel,
                                    delta: .empty,
                                    finishReason: generated.finishReason
                                ),
                                writer: writer
                            )
                        } else {
                            let (stream, _) = try await modelRuntime.generateStream(
                                messages: input.messages,
                                temperature: input.temperature,
                                maxTokens: input.max_tokens,
                                tools: requestedTools
                            )

                            try await writeSSEChunk(
                                makeStreamChunk(
                                    id: requestId,
                                    created: created,
                                    model: responseModel,
                                    delta: .assistantRole
                                ),
                                writer: writer
                            )

                            var sawToolCall = false
                            var sentTerminal = false
                            var streamedToolCallIndex = 0

                            for await generation in stream {
                                switch generation {
                                case .chunk(let text):
                                    guard !text.isEmpty else { continue }
                                    try await writeSSEChunk(
                                        makeStreamChunk(
                                            id: requestId,
                                            created: created,
                                            model: responseModel,
                                            delta: ChunkDelta(role: nil, content: text, tool_calls: nil)
                                        ),
                                        writer: writer
                                    )
                                case .toolCall(let toolCall):
                                    sawToolCall = true
                                    let streamToolCall = openAIToolCall(
                                        from: toolCall,
                                        id: "call_stream_\(streamedToolCallIndex)_\(UUID().uuidString.lowercased())",
                                        index: streamedToolCallIndex
                                    )
                                    streamedToolCallIndex += 1
                                    try await writeSSEChunk(
                                        makeStreamChunk(
                                            id: requestId,
                                            created: created,
                                            model: responseModel,
                                            delta: ChunkDelta(role: nil, content: nil, tool_calls: [streamToolCall])
                                        ),
                                        writer: writer
                                    )
                                case .info(let info):
                                    let finishReason: String
                                    if sawToolCall {
                                        finishReason = "tool_calls"
                                    } else {
                                        switch info.stopReason {
                                        case .length:
                                            finishReason = "length"
                                        case .cancelled, .stop:
                                            finishReason = "stop"
                                        }
                                    }

                                    try await writeSSEChunk(
                                        makeStreamChunk(
                                            id: requestId,
                                            created: created,
                                            model: responseModel,
                                            delta: .empty,
                                            finishReason: finishReason
                                        ),
                                        writer: writer
                                    )
                                    sentTerminal = true
                                }
                            }

                            if !sentTerminal {
                                try await writeSSEChunk(
                                    makeStreamChunk(
                                        id: requestId,
                                        created: created,
                                        model: responseModel,
                                        delta: .empty,
                                        finishReason: sawToolCall ? "tool_calls" : "stop"
                                    ),
                                    writer: writer
                                )
                            }
                        }

                        try await writeSSEDone(writer: writer)
                    } catch {
                        print("❌ [OpenAI API] Stream write failed: \(error)")
                        let _ = try? await writer.write(.end).get()
                    }
                }
            })
            return response
        }

        let generated = try await modelRuntime.generate(
            messages: input.messages,
            temperature: input.temperature,
            maxTokens: input.max_tokens,
            tools: requestedTools
        )

        let responseMessage = ChatMessage(
            role: "assistant",
            content: generated.toolCalls.isEmpty ? .text(generated.text) : nil,
            tool_calls: generated.toolCalls.isEmpty ? nil : generated.toolCalls
        )
        let choice = ChatChoice(index: 0, message: responseMessage, finish_reason: generated.finishReason)

        let actualUsage = ChatUsage(
            prompt_tokens: generated.promptTokens,
            completion_tokens: generated.completionTokens,
            total_tokens: generated.promptTokens + generated.completionTokens
        )
        print("✅ [OpenAI API] Response ready")

        let completionResponse = ChatCompletionResponse(
            id: "chatcmpl-\(UUID().uuidString.lowercased())",
            created: Int(Date().timeIntervalSince1970),
            model: input.model ?? config.model.path,
            choices: [choice],
            usage: actualUsage
        )

        return try makeJSONResponse(completionResponse)
    }
}
