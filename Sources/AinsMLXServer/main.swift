import Vapor
import MLX
import Yams
import Foundation

// 1. Define Swift structures mapping to the YAML structure
struct ServerConfig: Codable {
    struct ServerSettings: Codable {
        let port: Int
    }
    struct ModelSettings: Codable {
        let path: String
        let prompt_template: String
    }
    struct GenerationSettings: Codable {
        let max_tokens: Int
        let temperature: Float
        let top_p: Float
    }
    
    let server: ServerSettings
    let model: ModelSettings
    let generation: GenerationSettings
}

// 2. YAML configuration file loader (supports default values and local file discovery)
func loadConfiguration(from path: String?) throws -> ServerConfig {
    let decoder = YAMLDecoder()

    // 1. If path is provided via -c option (highest priority)
    if let userPath = path {
        return try loadFromFile(at: userPath)
    }
    
    // 2. If no -c option, check for config.yaml in the current directory
    let localConfigPath = FileManager.default.currentDirectoryPath + "/config.yaml"
    if FileManager.default.fileExists(atPath: localConfigPath) {
        print("📂 Local configuration file found: \(localConfigPath)")
        return try loadFromFile(at: localConfigPath)
    }
    
    // 3. Finally, parse and use the embedded configuration within the executable
    print("ℹ️ Configuration file not found. Using embedded default settings.")
    return try decoder.decode(ServerConfig.self, from: EmbeddedAssets.defaultConfigYAML)
}

func loadFromFile(at path: String) throws -> ServerConfig {
    let configURL = path.hasPrefix("/") ? URL(fileURLWithPath: path) : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(path)
    
    guard FileManager.default.fileExists(atPath: configURL.path) else {
        throw Abort(.internalServerError, reason: "Configuration file not found: \(path)")
    }
    
    let yamlString = try String(contentsOf: configURL, encoding: .utf8)
    let decoder = YAMLDecoder()
    return try decoder.decode(ServerConfig.self, from: yamlString)
}

// ==========================================
// 🚀 OpenAI API Specification Data Structures
// ==========================================
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


// ==========================================
// 🚀 Main Execution Logic
// ==========================================

var commandLineArgs = ProcessInfo.processInfo.arguments
var userConfigPath: String?

if let cIndex = commandLineArgs.firstIndex(of: "-c"), cIndex + 1 < commandLineArgs.count {
    userConfigPath = commandLineArgs[cIndex + 1]
    commandLineArgs.remove(at: cIndex + 1)
    commandLineArgs.remove(at: cIndex)
}

let config = try loadConfiguration(from: userConfigPath)

var env = try Environment.detect(arguments: commandLineArgs)
let app = try await Application.make(env)

// CORS Configuration
let corsConfiguration = CORSMiddleware.Configuration(
    allowedOrigin: .all,
    allowedMethods: [.GET, .POST, .PUT, .OPTIONS, .DELETE, .PATCH],
    allowedHeaders: [.accept, .authorization, .contentType, .origin, .xRequestedWith, .userAgent, .accessControlAllowOrigin]
)
app.middleware.use(CORSMiddleware(configuration: corsConfiguration), at: .beginning)

// Static File Middleware (works only if Public folder exists)
app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))

app.http.server.configuration.port = config.server.port

// ==========================================
// 🌐 Route Handling and Static File Serving (Embedded Assets Priority)
// ==========================================
app.get("**") { req -> Response in
    // 1. Check physical Public folder
    let filePath = app.directory.publicDirectory + req.url.path.dropFirst().description
    if FileManager.default.fileExists(atPath: filePath) {
        return req.fileio.asyncStreamFile(at: filePath)
    }
    
    // 2. Check embedded assets
    if let embeddedResponse = EmbeddedAssets.serve(req) {
        return embeddedResponse
    }
    
    // 3. If / path is requested and nothing found (index)
    if req.url.path == "/" {
        if let indexAsset = EmbeddedAssets.files["/"] {
            return Response(status: .ok, headers: ["Content-Type": indexAsset.type], body: .init(data: indexAsset.data))
        }
    }

    throw Abort(.notFound)
}

// ==========================================
// 🌐 API Endpoint (/v1/chat/completions)
// ==========================================
app.post("v1", "chat", "completions") { req async throws -> ChatCompletionResponse in
    let input = try req.content.decode(ChatCompletionRequest.self)
    
    let _ = input.messages.filter { $0.role == "user" }.map { $0.content }.joined(separator: "\n")
    print("📝 [OpenAI API] Request Received (Model: \(config.model.path))")
    
    let dummyText = "This is a default response from AinsMLXServer. Please connect actual model inference logic here."
    
    let responseMessage = ChatMessage(role: "assistant", content: dummyText)
    let choice = ChatChoice(index: 0, message: responseMessage, finish_reason: "stop")
    let usage = ChatUsage(prompt_tokens: 10, completion_tokens: 20, total_tokens: 30)
    
    return ChatCompletionResponse(
        id: "chatcmpl-\(UUID().uuidString.lowercased())",
        object: "chat.completion",
        created: Int(Date().timeIntervalSince1970),
        model: input.model ?? config.model.path,
        choices: [choice],
        usage: usage
    )
}

print("🌐 AinsMLXServer Starting (Port: \(config.server.port))")

try await app.execute()
try await app.asyncShutdown()
