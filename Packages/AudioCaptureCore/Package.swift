// swift-tools-version: 6.2
import PackageDescription

// Pure capture bookkeeping: the pre-roll ring, the promotion splice, and the
// frame accounting. No AVFoundation, so the one thing that must be
// sample-exact — the boundary between pre-threshold and session audio — is
// testable without a microphone, a run loop, or a real-time thread.
let package = Package(
    name: "AudioCaptureCore",
    platforms: [.macOS(.v26)],
    products: [.library(name: "AudioCaptureCore", targets: ["AudioCaptureCore"])],
    targets: [
        .target(
            name: "AudioCaptureCore",
            swiftSettings: [.swiftLanguageMode(.v6), .enableUpcomingFeature("ExistentialAny")]
        ),
        .testTarget(
            name: "AudioCaptureCoreTests",
            dependencies: ["AudioCaptureCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
