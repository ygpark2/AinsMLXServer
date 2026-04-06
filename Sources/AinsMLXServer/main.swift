import Foundation

@main
enum AinsMLXServerMain {
    static func main() async throws {
        try await ServerBootstrap.run()
    }
}
