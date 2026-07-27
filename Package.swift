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
        .executable(name: "app-audio-recorder", targets: ["AppAudioRecorder"])
    ],
    targets: [
        .executableTarget(
            name: "AppAudioRecorder",
            swiftSettings: strictConcurrency
        ),
        .testTarget(
            name: "AppAudioRecorderTests",
            dependencies: ["AppAudioRecorder"]
        ),
    ]
)
