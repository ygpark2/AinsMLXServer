import Foundation

enum ConversationReducer {
    static func ingest(messages: [ChatMessage]) -> ConversationState {
        var state = ConversationState()

        for message in messages {
            let events = explode(message: message)
            state.events.append(contentsOf: events)

            for event in events where event.kind == .assistantToolCall {
                if let toolCallID = event.toolCallID {
                    state.pendingToolCalls[toolCallID] = event
                }
            }
        }

        return state
    }

    private static func explode(message: ChatMessage) -> [ConversationEvent] {
        var events = [ConversationEvent]()
        let role = message.normalizedRole
        let content = message.content?.textForModel.trimmingCharacters(in: .whitespacesAndNewlines)

        if role == "assistant", let toolCalls = message.tool_calls, !toolCalls.isEmpty {
            for toolCall in toolCalls {
                events.append(
                    ConversationEvent(
                        kind: .assistantToolCall,
                        visibility: .modelVisible,
                        role: "assistant",
                        toolCallID: toolCall.id,
                        toolName: toolCall.function.name,
                        toolArgumentsJSON: toolCall.function.arguments
                    )
                )
            }
        }

        if let content, !content.isEmpty || message.tool_call_id != nil {
            let classified = classify(role: role, content: content)
            events.append(
                ConversationEvent(
                    kind: classified.kind,
                    visibility: classified.visibility,
                    role: role,
                    content: content,
                    name: message.name,
                    toolCallID: message.tool_call_id,
                    metadata: classified.metadata
                )
            )
        }

        return events
    }

    private static func classify(role: String, content: String) -> (
        kind: ConversationEventKind,
        visibility: EventVisibility,
        metadata: [String: String]
    ) {
        switch role {
        case "system":
            return (.systemPrompt, .modelVisible, [:])
        case "assistant":
            if content.hasPrefix("<think>") {
                return (.assistantMessage, .uiOnly, ["internal": "thinking"])
            }
            return (.assistantMessage, .modelVisible, [:])
        case "tool":
            if content.hasPrefix("Background task launched.") {
                return (.backgroundStatus, .uiOnly, ["internal": "background_task"])
            }
            if content.contains(" tool was called with invalid arguments:") {
                return (.toolError, .systemOnly, ["internal": "tool_validation"])
            }
            if content.contains("[Agent Usage Reminder]") {
                let trimmed = content.components(separatedBy: "\n[Agent Usage Reminder]").first ?? content
                return (.toolResult, .modelVisible, ["trimmed_content": trimmed])
            }
            return (.toolResult, .modelVisible, [:])
        default:
            if content.hasPrefix("<system-reminder>") {
                return (.reminder, .uiOnly, ["internal": "system_reminder"])
            }
            return (.userMessage, .modelVisible, [:])
        }
    }
}
