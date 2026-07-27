// swift-tools-version:6.2
import PackageDescription

let strictConcurrency: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]

let package = Package(
    name: "app-audio-recorder",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "AppAudioRecorderCore", targets: ["AppAudioRecorderCore"]),
        .executable(name: "app-audio-recorder", targets: ["AppAudioRecorderCLI"]),
        .executable(name: "app-audio-recorder-gui", targets: ["AppAudioRecorderGUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-log", from: "1.14.0"),
    ],
    targets: [
        .target(
            name: "AppAudioRecorderCore",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: strictConcurrency
        ),
        .executableTarget(
            name: "AppAudioRecorderCLI",
            dependencies: [
                "AppAudioRecorderCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: strictConcurrency
        ),
        .executableTarget(
            name: "AppAudioRecorderGUI",
            dependencies: [
                "AppAudioRecorderCore",
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: strictConcurrency
        ),
        .testTarget(
            name: "AppAudioRecorderCoreTests",
            dependencies: ["AppAudioRecorderCore"]
        ),
        .testTarget(
            name: "AppAudioRecorderCLITests",
            dependencies: ["AppAudioRecorderCLI"]
        ),
        .testTarget(
            name: "AppAudioRecorderGUITests",
            dependencies: ["AppAudioRecorderGUI"]
        ),
    ]
)
