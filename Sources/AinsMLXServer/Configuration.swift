import Foundation
import Vapor
import Yams

func loadDotEnv() {
    let envPath = FileManager.default.currentDirectoryPath + "/.env"
    guard let envString = try? String(contentsOfFile: envPath, encoding: .utf8) else { return }

    print("📝 [.env] Loading environment variables from .env file...")
    for line in envString.components(separatedBy: .newlines) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

        let parts = trimmed.split(separator: "=", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
        if parts.count == 2 {
            setenv(parts[0], parts[1], 1)
        }
    }
}

struct ServerConfig: Codable {
    struct ServerSettings: Codable {
        let port: Int
        let max_payload_size: String?
    }

    struct GenerationSettings: Codable {
        let max_tokens: Int
        let temperature: Float
        let top_p: Float
    }

    struct ModelSettings: Codable {
        let id: String
        let path: String
        let chat_template: String?
        let generation: GenerationSettings
    }

    struct RawConfig: Codable {
        let server: ServerSettings
        let active_model_id: String
        let available_models: [ModelSettings]
    }

    let server: ServerSettings
    let model: ModelSettings
}

func loadConfiguration(from path: String?) throws -> ServerConfig {
    let decoder = YAMLDecoder()
    let rawData: Data

    let resolvedPath: String?
    if let userPath = path {
        resolvedPath = userPath
    } else if let envPath = ProcessInfo.processInfo.environment["CONFIG_FILE"] {
        resolvedPath = envPath
    } else {
        resolvedPath = nil
    }

    if let userPath = resolvedPath {
        let configURL = userPath.hasPrefix("/")
            ? URL(fileURLWithPath: userPath)
            : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(userPath)

        guard FileManager.default.fileExists(atPath: configURL.path) else {
            throw Abort(.internalServerError, reason: "Configuration file not found: \(userPath)")
        }

        print("📂 Configuration file: \(userPath)")
        rawData = try Data(contentsOf: configURL)
    } else {
        let localConfigPath = FileManager.default.currentDirectoryPath + "/config.yaml"
        if FileManager.default.fileExists(atPath: localConfigPath) {
            print("📂 Local configuration file found: \(localConfigPath)")
            rawData = try Data(contentsOf: URL(fileURLWithPath: localConfigPath))
        } else {
            print("ℹ️ Configuration file not found. Using embedded default settings.")
            rawData = EmbeddedAssets.defaultConfigYAML.data(using: .utf8)!
        }
    }

    let rawConfig = try decoder.decode(ServerConfig.RawConfig.self, from: rawData)

    guard let selectedModel = rawConfig.available_models.first(where: { $0.id == rawConfig.active_model_id }) else {
        throw Abort(.internalServerError, reason: "Active model ID '\(rawConfig.active_model_id)' not found in available_models")
    }

    print("🎯 Active Model: \(selectedModel.id) (\(selectedModel.path))")
    return ServerConfig(server: rawConfig.server, model: selectedModel)
}
