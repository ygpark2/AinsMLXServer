import Foundation

enum ModelInputBuilder {
    static func build(from state: ConversationState) -> ModelTranscript {
        let rawMessages = state.events.compactMap { event -> ModelMessage? in
            guard event.visibility == .modelVisible else {
                return nil
            }

            switch event.kind {
            case .assistantToolCall:
                return ModelMessage(
                    role: "assistant",
                    content: "",
                    name: nil,
                    toolCallID: nil,
                    toolCalls: toolCall(event: event).map { [$0] }
                )
            default:
                guard let role = event.role else {
                    return nil
                }

                let content = event.metadata["trimmed_content"] ?? event.content ?? ""

                return ModelMessage(
                    role: role,
                    content: content,
                    name: event.name,
                    toolCallID: event.toolCallID,
                    toolCalls: nil
                )
            }
        }

        return ModelTranscript(messages: compress(messages: rawMessages))
    }

    private static func toolCall(event: ConversationEvent) -> OpenAIToolCall? {
        guard let toolCallID = event.toolCallID,
              let toolName = event.toolName,
              let arguments = event.toolArgumentsJSON else {
            return nil
        }

        return OpenAIToolCall(
            id: toolCallID,
            function: OpenAIFunctionCall(name: toolName, arguments: arguments)
        )
    }

    private static func compress(messages: [ModelMessage]) -> [ModelMessage] {
        let normalizedMessages = messages.filter { message in
            if message.role == "assistant",
               message.toolCalls == nil,
               message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return false
            }
            return true
        }

        var kept = [ModelMessage]()
        var recentToolSignatures = Set<String>()

        for message in normalizedMessages.reversed() {
            if let signature = toolResultSignature(for: message) {
                if recentToolSignatures.contains(signature) {
                    continue
                }
                recentToolSignatures.insert(signature)
            }

            kept.append(message)
        }

        kept.reverse()

        let systemPrefix = kept.prefix { $0.role == "system" }
        let remainder = Array(kept.dropFirst(systemPrefix.count))
        let userTurnIndexes = remainder.enumerated().compactMap { index, message in
            if message.role == "user",
               !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return index
            }
            return nil
        }

        let tailStartIndex: Int
        if userTurnIndexes.count >= 2 {
            tailStartIndex = userTurnIndexes[userTurnIndexes.count - 2]
        } else {
            tailStartIndex = 0
        }

        let preservedTail = Array(remainder.dropFirst(tailStartIndex))
        let combined = Array(systemPrefix) + preservedTail

        let maxMessages = 28
        if combined.count > maxMessages {
            return Array(combined.suffix(maxMessages))
        }
        return combined
    }

    private static func toolResultSignature(for message: ModelMessage) -> String? {
        guard message.role == "tool" else { return nil }

        let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return "tool:empty" }

        if content.hasPrefix("No matches found") {
            return "tool:no_matches"
        }
        if content.hasPrefix("No files found") {
            return "tool:no_files"
        }
        if content.hasPrefix("Found 1 match(es) in 1 file(s)") {
            return content
        }
        if content.hasPrefix("Found 1 file(s)") || content.hasPrefix("Found 2 file(s)") || content.hasPrefix("Found 3 file(s)") {
            return content
        }

        return nil
    }
}
