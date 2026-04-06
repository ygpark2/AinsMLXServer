import Vapor
import Foundation

func configureRoutes(on app: Application, config: ServerConfig, modelRuntime: ModelRuntime) {
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

    app.post("v1", "chat", "completions") { req async throws -> ChatCompletionResponse in
        let input = try req.content.decode(ChatCompletionRequest.self)

        print("📝 [OpenAI API] Request Received (Model: \(config.model.path))")

        let generated = try await modelRuntime.generate(
            messages: input.messages,
            temperature: input.temperature,
            maxTokens: input.max_tokens
        )

        let responseMessage = ChatMessage(role: "assistant", content: generated.text)
        let choice = ChatChoice(index: 0, message: responseMessage, finish_reason: generated.finishReason)

        let actualUsage = ChatUsage(
            prompt_tokens: generated.promptTokens,
            completion_tokens: generated.completionTokens,
            total_tokens: generated.promptTokens + generated.completionTokens
        )
        print("✅ [OpenAI API] Response ready")

        return ChatCompletionResponse(
            id: "chatcmpl-\(UUID().uuidString.lowercased())",
            object: "chat.completion",
            created: Int(Date().timeIntervalSince1970),
            model: input.model ?? config.model.path,
            choices: [choice],
            usage: actualUsage
        )
    }
}
