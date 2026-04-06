import Foundation
import MLX
import MLXLLM
import MLXLMCommon

func makeChatInput(from messages: [ChatMessage]) -> UserInput {
    let chatMessages: [Chat.Message] = messages.map { message in
        switch message.role {
        case "system":
            return .system(message.content)
        case "assistant":
            return .assistant(message.content)
        case "tool":
            return .tool(message.content)
        default:
            return .user(message.content)
        }
    }

    return UserInput(chat: chatMessages)
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

    func generate(
        messages: [ChatMessage],
        temperature: Float?,
        maxTokens: Int?
    ) async throws -> (text: String, promptTokens: Int, completionTokens: Int, finishReason: String) {
        let container = try await loadContainer()
        let userInput = makeChatInput(from: messages)
        let generationTemperature = temperature ?? config.model.generation.temperature
        let maxTokenLimit = maxTokens ?? config.model.generation.max_tokens
        let params = GenerateParameters(
            maxTokens: maxTokenLimit,
            temperature: generationTemperature,
            topP: config.model.generation.top_p,
            repetitionPenalty: 1.1
        )

        print("🧩 [Model] Preparing input...")
        let preparedInput = try await container.prepare(input: userInput)
        print("🧩 [Model] Input prepared")
        let promptTokenCount = preparedInput.text.tokens.size
        print("🧩 [Model] Starting generation (prompt tokens: \(promptTokenCount), max tokens: \(maxTokenLimit))")
        let stream = try await container.generate(input: preparedInput, parameters: params)

        var output = ""
        var completionInfo: GenerateCompletionInfo?
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
            case .toolCall:
                continue
            }
        }

        print("✅ [Model] Generation finished")

        let cleanedOutput = output
            .replacingOccurrences(of: "<end_of_turn>", with: "")
            .replacingOccurrences(of: "</s>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let finishReason: String
        switch completionInfo?.stopReason {
        case .length:
            finishReason = "length"
        case .cancelled:
            finishReason = "stop"
        case .stop, nil:
            finishReason = "stop"
        }

        return (
            text: cleanedOutput,
            promptTokens: promptTokenCount,
            completionTokens: completionInfo?.generationTokenCount ?? 0,
            finishReason: finishReason
        )
    }
}
