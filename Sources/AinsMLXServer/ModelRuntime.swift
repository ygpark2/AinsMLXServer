import Foundation
import MLX
import MLXLLM
import MLXLMCommon

typealias ToolSpec = [String: any Sendable]

struct ModelGenerationResult {
    let text: String
    let promptTokens: Int
    let completionTokens: Int
    let finishReason: String
    let toolCalls: [OpenAIToolCall]
}

func convertTools(_ tools: [RawTool]?) -> [ToolSpec]? {
    guard let tools, !tools.isEmpty else { return nil }
    return tools.map { tool in
        var function = [String: any Sendable](
            dictionaryLiteral:
                ("name", tool.function.name),
                ("description", tool.function.description ?? "")
        )
        if let parameters = tool.function.parameters?.sendableValue as? [String: any Sendable] {
            function["parameters"] = parameters
        }
        return [
            "type": tool.type,
            "function": function,
        ]
    }
}

func makeChatInput(from messages: [ChatMessage], tools: [ToolSpec]? = nil) -> UserInput {
    let chatMessages: [Chat.Message] = messages.map { message in
        let content = message.textForModel
        switch message.normalizedRole {
        case "system":
            return .system(content)
        case "assistant":
            return .assistant(content)
        case "tool":
            return .tool(content)
        default:
            return .user(content)
        }
    }

    return UserInput(chat: chatMessages, tools: tools)
}

func makeTokenizerMessages(from messages: [ChatMessage]) -> [[String: any Sendable]] {
    messages.compactMap { message in
        let content = message.textForModel
        guard !content.isEmpty || message.tool_calls != nil || message.tool_call_id != nil else {
            return nil
        }

        var payload: [String: any Sendable] = [
            "role": message.normalizedRole,
            "content": content,
        ]

        if let name = message.name, !name.isEmpty {
            payload["name"] = name
        }
        if let toolCallID = message.tool_call_id, !toolCallID.isEmpty {
            payload["tool_call_id"] = toolCallID
        }
        if let toolCalls = message.tool_calls, !toolCalls.isEmpty {
            payload["tool_calls"] = toolCalls.map { call in
                [
                    "id": call.id,
                    "type": call.type,
                    "function": [
                        "name": call.function.name,
                        "arguments": call.function.arguments,
                    ],
                ] as [String: any Sendable]
            }
        }

        return payload
    }
}

func toolArgumentsJSONString(_ arguments: [String: MLXLMCommon.JSONValue]) -> String {
    let jsonObject = arguments.mapValues { $0.anyValue }
    guard let data = try? JSONSerialization.data(withJSONObject: jsonObject, options: [.sortedKeys]) else {
        return "{}"
    }
    return String(decoding: data, as: UTF8.self)
}

func openAIToolCall(from toolCall: ToolCall, id: String, index: Int? = nil) -> OpenAIToolCall {
    return OpenAIToolCall(
        index: index,
        id: id,
        function: OpenAIFunctionCall(
            name: toolCall.function.name,
            arguments: toolArgumentsJSONString(toolCall.function.arguments)
        )
    )
}

actor ModelRuntime {
    private let config: ServerConfig
    private var modelContainer: ModelContainer?

    init(config: ServerConfig) {
        self.config = config
    }

    private func loadContainer() async throws -> ModelContainer {
        if let modelContainer {
            return modelContainer
        }

        print("🤖 [Model] Preparing container for \(config.model.path)...")

        let modelConfiguration = LLMModelFactory.shared.configuration(id: config.model.path)
        let loadingStartedAt = Date()
        let heartbeat = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                if Task.isCancelled { break }

                let elapsed = Int(Date().timeIntervalSince(loadingStartedAt))
                print("⏳ [Model] Still loading \(config.model.path)... \(elapsed)s elapsed")
            }
        }

        let container = try await LLMModelFactory.shared.loadContainer(configuration: modelConfiguration) { progress in
            let percent = Int(progress.fractionCompleted * 100)
            let mbCompleted = progress.completedUnitCount / 1_048_576
            let mbTotal = progress.totalUnitCount > 0 ? progress.totalUnitCount / 1_048_576 : 0
            print("⏳ [Model] Loading weights into memory: \(percent)% (\(mbCompleted)MB / \(mbTotal)MB)", terminator: "\r")
            fflush(stdout)
        }
        heartbeat.cancel()
        print("")
        print("\n✅ [Model] Container loaded for \(config.model.path)")
        modelContainer = container
        return container
    }

    private func generationParameters(temperature: Float?, maxTokens: Int?) -> GenerateParameters {
        let generationTemperature = temperature ?? config.model.generation.temperature
        let maxTokenLimit = maxTokens ?? config.model.generation.max_tokens
        return GenerateParameters(
            maxTokens: maxTokenLimit,
            temperature: generationTemperature,
            topP: config.model.generation.top_p,
            repetitionPenalty: 1.1
        )
    }

    private func runGeneration(
        messages: [ChatMessage],
        temperature: Float?,
        maxTokens: Int?,
        tools: [ToolSpec]? = nil
    ) async throws -> (stream: AsyncStream<Generation>, promptTokenCount: Int) {
        guard !messages.isEmpty else {
            throw NSError(domain: "AinsMLXServer", code: 400, userInfo: [NSLocalizedDescriptionKey: "At least one message is required."])
        }

        let container = try await loadContainer()
        let params = generationParameters(temperature: temperature, maxTokens: maxTokens)
        let tokenizerMessages = makeTokenizerMessages(from: messages)
        print("🧩 [Model] Preparing input...")
        let (stream, promptTokenCount) = try await container.perform { context in
            let tokenIDs = try context.tokenizer.applyChatTemplate(
                messages: tokenizerMessages,
                chatTemplate: nil,
                addGenerationPrompt: true,
                truncation: false,
                maxLength: nil,
                tools: tools
            )

            let promptTokenCount = tokenIDs.count
            let maxTokensDescription = params.maxTokens.map(String.init) ?? "nil"
            print("🧩 [Model] Starting generation (prompt tokens: \(promptTokenCount), max tokens: \(maxTokensDescription))")

            let preparedInput = LMInput(tokens: MLXArray(tokenIDs))
            let stream = try MLXLMCommon.generate(input: preparedInput, parameters: params, context: context)
            return (stream, promptTokenCount)
        }
        return (stream: stream, promptTokenCount: promptTokenCount)
    }

    func generate(
        messages: [ChatMessage],
        temperature: Float?,
        maxTokens: Int?,
        tools: [RawTool]? = nil
    ) async throws -> ModelGenerationResult {
        try await generate(
            messages: messages,
            temperature: temperature,
            maxTokens: maxTokens,
            tools: tools,
            repairAttempted: false,
            textFallbackAttempted: false
        )
    }

    private func generate(
        messages: [ChatMessage],
        temperature: Float?,
        maxTokens: Int?,
        tools: [RawTool]?,
        repairAttempted: Bool,
        textFallbackAttempted: Bool
    ) async throws -> ModelGenerationResult {
        let normalizationContext = toolNormalizationContext(from: messages)
        let mlxTools = convertTools(tools)
        let (stream, promptTokenCount) = try await runGeneration(
            messages: messages,
            temperature: temperature,
            maxTokens: maxTokens,
            tools: mlxTools
        )

        var output = ""
        var completionInfo: GenerateCompletionInfo?
        var toolCalls = [ToolCall]()
        var sawChunk = false

        for await generation in stream {
            switch generation {
            case .chunk(let text):
                if !sawChunk {
                    print("🧩 [Model] First chunk received")
                    sawChunk = true
                }
                output += text
            case .info(let info):
                completionInfo = info
            case .toolCall(let toolCall):
                toolCalls.append(toolCall)
            }
        }

        let completionTokens = completionInfo?.generationTokenCount ?? 0
        print("✅ [Model] Generation finished")

        let cleanedOutput = output
            .replacingOccurrences(of: "<end_of_turn>", with: "")
            .replacingOccurrences(of: "</s>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if !toolCalls.isEmpty {
            let openAIToolCalls = normalizeToolCalls(
                toolCalls.enumerated().map { index, toolCall in
                    openAIToolCall(from: toolCall, id: "call_\(index)_\(UUID().uuidString.lowercased())")
                },
                allowedTools: tools,
                context: normalizationContext
            )
            let validation = partitionToolCalls(openAIToolCalls, allowedTools: tools)
            if !validation.invalid.isEmpty {
                let summary = validation.invalid.map { "\($0.function.name)(\($0.function.arguments))" }.joined(separator: ", ")
                print("⚠️ [Tool Calls] Invalid generated tool calls: \(summary)")
                if !repairAttempted, let repaired = try await repairInvalidToolCalls(
                    messages: messages,
                    temperature: temperature,
                    maxTokens: maxTokens,
                    tools: tools,
                    invalidToolCalls: validation.invalid,
                    validationErrors: validation.errors
                ) {
                    return repaired
                }
                if !validation.valid.isEmpty {
                    print("🧩 [Tool Calls] Dropping \(validation.invalid.count) invalid tool call(s), keeping \(validation.valid.count) valid call(s)")
                } else {
                    print("🧩 [Tool Calls] Dropping \(validation.invalid.count) invalid tool call(s)")
                }
            }
            guard !validation.valid.isEmpty else {
                if !textFallbackAttempted {
                    return try await recoverAsTextAfterInvalidToolCalls(
                        messages: messages,
                        temperature: temperature,
                        maxTokens: maxTokens
                    )
                }
                return ModelGenerationResult(
                    text: cleanedOutput,
                    promptTokens: promptTokenCount,
                    completionTokens: completionTokens,
                    finishReason: "stop",
                    toolCalls: []
                )
            }
            return ModelGenerationResult(
                text: cleanedOutput,
                promptTokens: promptTokenCount,
                completionTokens: completionTokens,
                finishReason: "tool_calls",
                toolCalls: validation.valid
            )
        }

        let parsedFallbackToolCalls = fallbackToolCalls(from: cleanedOutput, allowedTools: tools)
        if !parsedFallbackToolCalls.isEmpty {
            print("🧩 [Model] Promoted textual tool-call output into structured tool_calls")
            let validation = partitionToolCalls(parsedFallbackToolCalls, allowedTools: tools)
            if !validation.invalid.isEmpty {
                let summary = validation.invalid.map { "\($0.function.name)(\($0.function.arguments))" }.joined(separator: ", ")
                print("⚠️ [Tool Calls] Invalid fallback tool calls: \(summary)")
                if !repairAttempted, let repaired = try await repairInvalidToolCalls(
                    messages: messages,
                    temperature: temperature,
                    maxTokens: maxTokens,
                    tools: tools,
                    invalidToolCalls: validation.invalid,
                    validationErrors: validation.errors
                ) {
                    return repaired
                }
                if !validation.valid.isEmpty {
                    print("🧩 [Tool Calls] Dropping \(validation.invalid.count) invalid fallback tool call(s), keeping \(validation.valid.count) valid call(s)")
                } else {
                    print("🧩 [Tool Calls] Dropping \(validation.invalid.count) invalid fallback tool call(s)")
                }
            }
            guard !validation.valid.isEmpty else {
                if !textFallbackAttempted {
                    return try await recoverAsTextAfterInvalidToolCalls(
                        messages: messages,
                        temperature: temperature,
                        maxTokens: maxTokens
                    )
                }
                return ModelGenerationResult(
                    text: cleanedOutput,
                    promptTokens: promptTokenCount,
                    completionTokens: completionTokens,
                    finishReason: "stop",
                    toolCalls: []
                )
            }
            return ModelGenerationResult(
                text: "",
                promptTokens: promptTokenCount,
                completionTokens: completionTokens,
                finishReason: "tool_calls",
                toolCalls: validation.valid
            )
        }

        let finishReason: String
        switch completionInfo?.stopReason {
        case .length:
            finishReason = "length"
        case .cancelled:
            finishReason = "stop"
        case .stop, nil:
            finishReason = "stop"
        }

        return ModelGenerationResult(
            text: cleanedOutput,
            promptTokens: promptTokenCount,
            completionTokens: completionTokens,
            finishReason: finishReason,
            toolCalls: []
        )
    }

    private func repairInvalidToolCalls(
        messages: [ChatMessage],
        temperature: Float?,
        maxTokens: Int?,
        tools: [RawTool]?,
        invalidToolCalls: [OpenAIToolCall],
        validationErrors: [String]
    ) async throws -> ModelGenerationResult? {
        guard let tools, !tools.isEmpty else { return nil }
        let invalidToolNames = Set(invalidToolCalls.map { $0.function.name })
        let repairTools = tools.filter { invalidToolNames.contains($0.function.name) }
        let schemas = toolSchemas(from: repairTools)
        let schemaHints = invalidToolNames.sorted().compactMap { name -> String? in
            guard let schema = schemas[name] else { return nil }
            let required = schema.required.sorted()
            guard !required.isEmpty else { return "\(name): return a valid JSON object" }
            return "\(name): required keys = \(required.joined(separator: ", "))"
        }

        let repairInstruction = """
        Your previous tool call was invalid.
        Return corrected tool_calls only.
        Do not explain anything.
        Use only these tool names: \(invalidToolNames.sorted().joined(separator: ", "))
        Schema:
        \(schemaHints.joined(separator: "\n"))
        Validation errors:
        \(validationErrors.joined(separator: "\n"))
        """

        print("🔧 [Tool Calls] Attempting one-shot repair for invalid tool call schema")

        return try await generate(
            messages: messages + [ChatMessage(role: "user", text: repairInstruction)],
            temperature: temperature,
            maxTokens: maxTokens,
            tools: repairTools,
            repairAttempted: true,
            textFallbackAttempted: false
        )
    }

    private func recoverAsTextAfterInvalidToolCalls(
        messages: [ChatMessage],
        temperature: Float?,
        maxTokens: Int?
    ) async throws -> ModelGenerationResult {
        let recoveryInstruction = """
        Your last tool call was invalid and will not be executed.
        Do not call any more tools.
        Continue with a normal assistant response using only the tool results already present in the conversation.
        """

        print("🧩 [Tool Calls] Falling back to text-only response after dropping invalid tool calls")

        return try await generate(
            messages: messages + [ChatMessage(role: "user", text: recoveryInstruction)],
            temperature: temperature,
            maxTokens: maxTokens,
            tools: nil,
            repairAttempted: true,
            textFallbackAttempted: true
        )
    }

    func generateStream(
        messages: [ChatMessage],
        temperature: Float?,
        maxTokens: Int?,
        tools: [RawTool]? = nil
    ) async throws -> (stream: AsyncStream<Generation>, promptTokenCount: Int) {
        try await runGeneration(
            messages: messages,
            temperature: temperature,
            maxTokens: maxTokens,
            tools: convertTools(tools)
        )
    }
}
