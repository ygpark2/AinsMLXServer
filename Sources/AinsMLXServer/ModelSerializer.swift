import Foundation

enum ModelSerializationStrategy {
    case genericMLX
    case qwen
    case glm
    case nemotron

    static func resolve(modelID: String, modelPath: String) -> ModelSerializationStrategy {
        let normalizedID = modelID.lowercased()
        let normalizedPath = modelPath.lowercased()

        if normalizedID.contains("glm") || normalizedPath.contains("glm") {
            return .glm
        }
        if normalizedID.contains("nemotron") || normalizedPath.contains("nemotron") {
            return .nemotron
        }
        if normalizedID.contains("qwen") || normalizedPath.contains("qwen") {
            return .qwen
        }

        return .genericMLX
    }
}

enum ModelSerializer {
    static func serialize(
        transcript: ModelTranscript,
        strategy: ModelSerializationStrategy
    ) -> [ChatMessage] {
        switch strategy {
        case .genericMLX:
            return serializeGenericMLX(transcript: transcript)
        case .qwen:
            return serializeQwen(transcript: transcript)
        case .glm:
            return serializeGLM(transcript: transcript)
        case .nemotron:
            return serializeNemotron(transcript: transcript)
        }
    }

    private static func serializeGenericMLX(transcript: ModelTranscript) -> [ChatMessage] {
        transcript.messages.map(serializeMessage)
    }

    private static func serializeQwen(transcript: ModelTranscript) -> [ChatMessage] {
        let prunedMessages = pruneForQwen(transcript.messages)
        return prunedMessages.map(serializeMessage)
    }

    private static func serializeGLM(transcript: ModelTranscript) -> [ChatMessage] {
        let preservedMessages = preserveForGLM(transcript.messages)
        return preservedMessages.map(serializeMessage)
    }

    private static func serializeNemotron(transcript: ModelTranscript) -> [ChatMessage] {
        transcript.messages.map(serializeMessage)
    }

    private static func serializeMessage(_ message: ModelMessage) -> ChatMessage {
        ChatMessage(
            role: message.role,
            content: .text(message.content),
            name: message.name,
            tool_calls: message.toolCalls,
            tool_call_id: message.toolCallID
        )
    }

    private static func pruneForQwen(_ messages: [ModelMessage]) -> [ModelMessage] {
        let systemMessages = messages.filter { $0.role == "system" }
        let nonSystemMessages = messages.filter { $0.role != "system" }
        let lastUserMessage = nonSystemMessages.last { message in
            message.role == "user" && !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        let lastUserIndex = nonSystemMessages.lastIndex { message in
            message.role == "user" && !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        let tailMessages: [ModelMessage]
        if let lastUserIndex {
            tailMessages = Array(nonSystemMessages[lastUserIndex...])
        } else {
            tailMessages = nonSystemMessages
        }

        let reducedTail = tailMessages.compactMap { message -> ModelMessage? in
            if message.role == "assistant",
               message.toolCalls == nil,
               shouldDropAssistantNarrationForQwen(message.content) {
                return nil
            }

            if message.role == "tool" {
                return ModelMessage(
                    role: message.role,
                    content: truncateToolContentForQwen(message.content),
                    name: message.name,
                    toolCallID: message.toolCallID,
                    toolCalls: message.toolCalls
                )
            }

            return message
        }

        let combined = systemMessages + reducedTail
        var ensured = combined

        if let lastUserMessage,
           !ensured.contains(where: { message in
               message.role == "user" && message.content == lastUserMessage.content
           }) {
            let insertIndex = ensured.prefix { $0.role == "system" }.count
            ensured.insert(lastUserMessage, at: insertIndex)
        }

        let maxMessages = 12
        return clampQwenMessages(ensured, lastUserMessage: lastUserMessage, maxMessages: maxMessages)
    }

    private static func shouldDropAssistantNarrationForQwen(_ content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        let prefixes = [
            "I detect ",
            "`grep`",
            "`gpt-5-nano`",
            "더 넓은 범위로 다시 검색해 보겠습니다.",
            "더 광범위한 패턴을 찾도록",
            "에이전트가 모델 설정과 관련된 파일을 찾는 동안"
        ]

        return prefixes.contains { trimmed.hasPrefix($0) }
    }

    private static func truncateToolContentForQwen(_ content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        let lines = trimmed.components(separatedBy: .newlines)
        let maxLines = 12
        if lines.count <= maxLines {
            return trimmed
        }

        let head = lines.prefix(maxLines).joined(separator: "\n")
        return head + "\n...[truncated]"
    }

    private static func clampQwenMessages(
        _ messages: [ModelMessage],
        lastUserMessage: ModelMessage?,
        maxMessages: Int
    ) -> [ModelMessage] {
        guard messages.count > maxMessages else { return messages }

        let preservedSystem = Array(messages.prefix { $0.role == "system" })
        var nonSystem = Array(messages.dropFirst(preservedSystem.count))
        let budget = max(1, maxMessages - preservedSystem.count)

        if nonSystem.count > budget {
            nonSystem = Array(nonSystem.suffix(budget))
        }

        if let lastUserMessage,
           !nonSystem.contains(where: { message in
               message.role == "user" && message.content == lastUserMessage.content
           }) {
            if !nonSystem.isEmpty {
                nonSystem.removeFirst()
            }
            nonSystem.insert(lastUserMessage, at: 0)
        }

        return preservedSystem + nonSystem
    }

    private static func preserveForGLM(_ messages: [ModelMessage]) -> [ModelMessage] {
        let normalizedMessages = messages.filter { message in
            if message.role == "assistant",
               message.toolCalls == nil,
               message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return false
            }
            return true
        }

        let systemMessages = normalizedMessages.filter { $0.role == "system" }
        let nonSystemMessages = normalizedMessages.filter { $0.role != "system" }

        let userTurnIndexes = nonSystemMessages.enumerated().compactMap { index, message in
            if message.role == "user",
               !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return index
            }
            return nil
        }

        let tailStartIndex: Int
        if userTurnIndexes.count >= 3 {
            tailStartIndex = userTurnIndexes[userTurnIndexes.count - 3]
        } else {
            tailStartIndex = 0
        }

        let tailMessages = Array(nonSystemMessages.dropFirst(tailStartIndex)).map { message in
            if message.role == "tool" {
                return ModelMessage(
                    role: message.role,
                    content: truncateToolContentForGLM(message.content),
                    name: message.name,
                    toolCallID: message.toolCallID,
                    toolCalls: message.toolCalls
                )
            }
            return message
        }

        let combined = systemMessages + tailMessages
        let maxMessages = 20
        if combined.count > maxMessages {
            let preservedSystem = combined.prefix { $0.role == "system" }
            let nonSystemSuffix = combined.dropFirst(preservedSystem.count).suffix(maxMessages - preservedSystem.count)
            return Array(preservedSystem) + nonSystemSuffix
        }

        return combined
    }

    private static func truncateToolContentForGLM(_ content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        let lines = trimmed.components(separatedBy: .newlines)
        let maxLines = 24
        if lines.count <= maxLines {
            return trimmed
        }

        let head = lines.prefix(maxLines).joined(separator: "\n")
        return head + "\n...[truncated]"
    }
}
