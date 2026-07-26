// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "app-audio-recorder",
    // ScreenCaptureKit 的 SCShareableContent.current / 按 app 音频过滤在 macOS 14+ 上稳定可用。
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "app-audio-recorder", targets: ["AppAudioRecorder"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "AppAudioRecorder",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
    ]
)
