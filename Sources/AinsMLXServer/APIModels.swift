import Vapor

struct ChatMessage: Content {
    let role: String
    let content: String
}

struct ChatCompletionRequest: Content {
    let model: String?
    let messages: [ChatMessage]
    let temperature: Float?
    let max_tokens: Int?
}

struct ChatChoice: Content {
    let index: Int
    let message: ChatMessage
    let finish_reason: String
}

struct ChatUsage: Content {
    let prompt_tokens: Int
    let completion_tokens: Int
    let total_tokens: Int
}

struct ChatCompletionResponse: Content {
    let id: String
    let object: String
    let created: Int
    let model: String
    let choices: [ChatChoice]
    let usage: ChatUsage
}
