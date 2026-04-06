import Vapor
import Foundation

enum ServerBootstrap {
    static func run() async throws {
        loadDotEnv()

        var commandLineArgs = ProcessInfo.processInfo.arguments
        let userConfigPath = extractConfigurationPath(from: &commandLineArgs)

        let config = try loadConfiguration(from: userConfigPath)
        let modelRuntime = ModelRuntime(config: config)

        await preloadModel(modelRuntime, modelId: config.model.id)

        let env = try Environment.detect(arguments: commandLineArgs)
        let app = try await Application.make(env)

        configureMiddleware(on: app)
        app.http.server.configuration.port = config.server.port

        configureRoutes(on: app, config: config, modelRuntime: modelRuntime)

        print("🌐 AinsMLXServer Starting (Port: \(config.server.port))")
        try await app.execute()
        try await app.asyncShutdown()
    }

    private static func extractConfigurationPath(from arguments: inout [String]) -> String? {
        guard let cIndex = arguments.firstIndex(of: "-c"), cIndex + 1 < arguments.count else {
            return nil
        }

        let configPath = arguments[cIndex + 1]
        arguments.remove(at: cIndex + 1)
        arguments.remove(at: cIndex)
        return configPath
    }

    private static func preloadModel(_ modelRuntime: ModelRuntime, modelId: String) async {
        print("🚀 [System] Pre-loading model: \(modelId)...")
        do {
            _ = try await modelRuntime.generate(messages: [], temperature: nil, maxTokens: 1)
            print("✅ [System] Model pre-loaded successfully.")
        } catch {
            print("❌ [System] Failed to pre-load model: \(error)")
            print("💡 Tip: Check your internet connection or try deleting the model cache.")
        }
    }

    private static func configureMiddleware(on app: Application) {
        let corsConfiguration = CORSMiddleware.Configuration(
            allowedOrigin: .all,
            allowedMethods: [.GET, .POST, .PUT, .OPTIONS, .DELETE, .PATCH],
            allowedHeaders: [.accept, .authorization, .contentType, .origin, .xRequestedWith, .userAgent, .accessControlAllowOrigin]
        )
        app.middleware.use(CORSMiddleware(configuration: corsConfiguration), at: .beginning)
    }
}
