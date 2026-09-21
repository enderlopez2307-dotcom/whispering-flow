// swift-tools-version: 6.2
import PackageDescription

// Pure text-processing core. No AppKit, no I/O, no clocks, no system calls.
// Everything here must be unit-testable without launching an app.
let package = Package(
    name: "TextProcessingCore",
    platforms: [.macOS(.v26)],
    products: [.library(name: "TextProcessingCore", targets: ["TextProcessingCore"])],
    targets: [
        .target(
            name: "TextProcessingCore",
            swiftSettings: [.swiftLanguageMode(.v6), .enableUpcomingFeature("ExistentialAny")]
        ),
        .testTarget(
            name: "TextProcessingCoreTests",
            dependencies: ["TextProcessingCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
