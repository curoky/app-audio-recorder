// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "app-audio-recorder",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "app-audio-recorder", targets: ["AppAudioRecorder"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-log", from: "1.14.0"),
        .package(url: "https://github.com/apple/swift-async-algorithms", from: "1.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "AppAudioRecorder",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
            ],
            swiftSettings: [
                // Swift 6.2 Approachable Concurrency：v6 语言模式 + 完整数据竞争检查。
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
            ]
        ),
        .testTarget(
            name: "AppAudioRecorderTests",
            dependencies: ["AppAudioRecorder"]
        ),
    ]
)
