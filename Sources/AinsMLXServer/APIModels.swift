import Vapor
import Foundation

struct ChatMessage: Content, Sendable {
    let role: String
    let content: MessageContent?
    let name: String?
    let tool_calls: [OpenAIToolCall]?
    let tool_call_id: String?

    init(
        role: String,
        content: MessageContent? = nil,
        name: String? = nil,
        tool_calls: [OpenAIToolCall]? = nil,
        tool_call_id: String? = nil
    ) {
        self.role = role
        self.content = content
        self.name = name
        self.tool_calls = tool_calls
        self.tool_call_id = tool_call_id
    }

    init(role: String, text: String) {
        self.init(role: role, content: .text(text))
    }

    var normalizedRole: String {
        switch role.lowercased() {
        case "system", "developer":
            return "system"
        case "assistant":
            return "assistant"
        case "tool", "function":
            return "tool"
        default:
            return "user"
        }
    }

    var textForModel: String {
        var parts = [String]()

        if let name, !name.isEmpty {
            parts.append("name=\(name)")
        }

        if let contentText = content?.textForModel, !contentText.isEmpty {
            parts.append(contentText)
        }

        if let toolCalls = tool_calls, !toolCalls.isEmpty {
            let renderedCalls = toolCalls.map { call in
                "tool_call(id=\(call.id), name=\(call.function.name), arguments=\(call.function.arguments))"
            }.joined(separator: "\n")
            parts.append(renderedCalls)
        }

        if let toolCallID = tool_call_id, !toolCallID.isEmpty {
            parts.append("tool_call_id=\(toolCallID)")
        }

        return parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var debugSummary: String {
        let preview = textForModel
            .replacingOccurrences(of: "\n", with: "\\n")
            .prefix(240)
        return "role=\(role) mapped=\(normalizedRole) content=\"\(preview)\" tool_calls=\(tool_calls?.count ?? 0) tool_call_id=\(tool_call_id ?? "-")"
    }

    private enum CodingKeys: String, CodingKey {
        case role
        case content
        case name
        case tool_calls
        case tool_call_id
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        if let content {
            try container.encode(content, forKey: .content)
        } else {
            try container.encodeNil(forKey: .content)
        }
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(tool_calls, forKey: .tool_calls)
        try container.encodeIfPresent(tool_call_id, forKey: .tool_call_id)
    }
}

enum MessageContent: Codable, Sendable {
    case text(String)
    case parts([ContentPart])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .text("")
        } else if let text = try? container.decode(String.self) {
            self = .text(text)
        } else if let parts = try? container.decode([ContentPart].self) {
            self = .parts(parts)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Content must be a string, null, or an array of content parts")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text):
            try container.encode(text)
        case .parts(let parts):
            try container.encode(parts)
        }
    }

    var textForModel: String {
        switch self {
        case .text(let text):
            return text
        case .parts(let parts):
            return parts.compactMap(\.textForModel).joined(separator: "\n")
        }
    }
}

struct ContentPart: Codable, Sendable {
    let type: String
    let text: String?
    let image_url: ImageURLPayload?

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case image_url
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        text = try container.decodeIfPresent(String.self, forKey: .text)

        if let payload = try? container.decode(ImageURLPayload.self, forKey: .image_url) {
            image_url = payload
        } else if let urlString = try? container.decode(String.self, forKey: .image_url) {
            image_url = ImageURLPayload(url: urlString, detail: nil)
        } else {
            image_url = nil
        }
    }

    var textForModel: String? {
        switch type {
        case "text", "input_text":
            return text
        case "image_url", "input_image":
            guard let url = image_url?.url, !url.isEmpty else {
                return "[image]"
            }
            return "[image: \(url)]"
        default:
            if let text, !text.isEmpty {
                return text
            }
            return "[\(type)]"
        }
    }
}

struct ImageURLPayload: Codable, Sendable {
    let url: String
    let detail: String?
}

struct ChatCompletionRequest: Content {
    let model: String?
    let messages: [ChatMessage]
    let temperature: Float?
    let top_p: Float?
    let max_tokens: Int?
    let stream: Bool?
    let stop: [String]?
    let presence_penalty: Float?
    let frequency_penalty: Float?
    let logit_bias: [Int: Float]?
    let user: String?
    let tools: [RawTool]?
    let tool_choice: ToolChoice?
}

struct RawTool: Content {
    let type: String
    let function: RawFunction
}

struct RawFunction: Content {
    let name: String
    let description: String?
    let parameters: APIJSONValue?
}

struct ToolChoice: Codable {
    let mode: String?
    let functionName: String?

    init(mode: String? = nil, functionName: String? = nil) {
        self.mode = mode
        self.functionName = functionName
    }

    init(from decoder: Decoder) throws {
        let singleValueContainer = try decoder.singleValueContainer()
        if let mode = try? singleValueContainer.decode(String.self) {
            self.init(mode: mode)
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decodeIfPresent(String.self, forKey: .type)
        let function = try container.decodeIfPresent(NamedToolFunction.self, forKey: .function)
        self.init(mode: type, functionName: function?.name)
    }

    func encode(to encoder: Encoder) throws {
        if functionName == nil, let mode {
            var container = encoder.singleValueContainer()
            try container.encode(mode)
            return
        }

        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mode ?? "function", forKey: .type)
        if let functionName {
            try container.encode(NamedToolFunction(name: functionName), forKey: .function)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case function
    }

    private struct NamedToolFunction: Codable {
        let name: String
    }
}

enum APIJSONValue: Codable, Sendable {
    case string(String)
    case int(Int)
    case number(Double)
    case bool(Bool)
    case object([String: APIJSONValue])
    case array([APIJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: APIJSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([APIJSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var sendableValue: any Sendable {
        switch self {
        case .string(let value):
            return value
        case .int(let value):
            return value
        case .number(let value):
            return value
        case .bool(let value):
            return value
        case .object(let value):
            return value.mapValues { $0.sendableValue }
        case .array(let value):
            return value.map { $0.sendableValue }
        case .null:
            return "null"
        }
    }

    var jsonString: String {
        guard let data = try? JSONEncoder().encode(self) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }
}

struct OpenAIToolCall: Codable, Hashable, Sendable {
    let index: Int?
    let id: String
    let type: String
    let function: OpenAIFunctionCall

    init(index: Int? = nil, id: String, type: String = "function", function: OpenAIFunctionCall) {
        self.index = index
        self.id = id
        self.type = type
        self.function = function
    }
}

struct OpenAIFunctionCall: Codable, Hashable, Sendable {
    let name: String
    let arguments: String
}

struct ChatChoice: Encodable {
    let index: Int
    let message: ChatMessage
    let finish_reason: String
}

struct ChatUsage: Encodable {
    let prompt_tokens: Int
    let completion_tokens: Int
    let total_tokens: Int
}

struct ChatCompletionResponse: Encodable {
    let id: String
    let object: String = "chat.completion"
    let created: Int
    let model: String
    let choices: [ChatChoice]
    let usage: ChatUsage
}

struct ChatCompletionChunk: Encodable {
    let id: String
    let object: String = "chat.completion.chunk"
    let created: Int
    let model: String
    let choices: [ChunkChoice]
}

struct ChunkChoice: Encodable {
    let index: Int
    let delta: ChunkDelta
    let finish_reason: String?
}

struct ChunkDelta: Encodable {
    let role: String?
    let content: String?
    let tool_calls: [OpenAIToolCall]?

    static let assistantRole = ChunkDelta(role: "assistant", content: nil, tool_calls: nil)
    static let empty = ChunkDelta(role: nil, content: nil, tool_calls: nil)
}
