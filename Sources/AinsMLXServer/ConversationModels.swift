import Foundation

enum EventVisibility: String, Codable, Sendable {
    case modelVisible
    case uiOnly
    case systemOnly
}

enum ConversationEventKind: String, Codable, Sendable {
    case systemPrompt
    case userMessage
    case assistantMessage
    case assistantToolCall
    case toolResult
    case toolError
    case backgroundStatus
    case reminder
    case summary
}

struct ConversationEvent: Codable, Sendable, Identifiable {
    let id: UUID
    let createdAt: Date
    let kind: ConversationEventKind
    let visibility: EventVisibility
    let role: String?
    let content: String?
    let name: String?
    let toolCallID: String?
    let toolName: String?
    let toolArgumentsJSON: String?
    let metadata: [String: String]

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        kind: ConversationEventKind,
        visibility: EventVisibility,
        role: String? = nil,
        content: String? = nil,
        name: String? = nil,
        toolCallID: String? = nil,
        toolName: String? = nil,
        toolArgumentsJSON: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.createdAt = createdAt
        self.kind = kind
        self.visibility = visibility
        self.role = role
        self.content = content
        self.name = name
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.toolArgumentsJSON = toolArgumentsJSON
        self.metadata = metadata
    }
}

struct ConversationState: Sendable {
    var events: [ConversationEvent]
    var summaries: [ConversationEvent]
    var pendingToolCalls: [String: ConversationEvent]

    init(
        events: [ConversationEvent] = [],
        summaries: [ConversationEvent] = [],
        pendingToolCalls: [String: ConversationEvent] = [:]
    ) {
        self.events = events
        self.summaries = summaries
        self.pendingToolCalls = pendingToolCalls
    }
}

struct ModelMessage: Sendable {
    let role: String
    let content: String
    let name: String?
    let toolCallID: String?
    let toolCalls: [OpenAIToolCall]?
}

struct ModelTranscript: Sendable {
    let messages: [ModelMessage]
}
