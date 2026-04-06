// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "AinsMLXServer",
    platforms: [
        .macOS(.v14) // MLX는 최신 macOS 환경을 권장합니다.
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.89.0"),
        // Apple 공식 MLX Swift 바인딩
        .package(url: "https://github.com/ml-explore/mlx-swift.git", from: "0.10.0"), // ✅ 콤마 추가
        // YAML 파싱을 위한 Yams 라이브러리 추가
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0")
    ],
    targets: [
        .executableTarget(
            name: "AinsMLXServer",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXRandom", package: "mlx-swift"),
                .product(name: "Yams", package: "Yams") // Yams 타겟 추가
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
