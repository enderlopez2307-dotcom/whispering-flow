// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WhisperingFlow",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "WhisperingFlow", targets: ["WhisperingFlow"])
    ],
    dependencies: [
        .package(path: "Packages/TextProcessingCore"),
        .package(path: "Packages/HotkeyGestureCore"),
        .package(path: "Packages/AudioCaptureCore"),
        // FluidAudio is deliberately absent from V1 (ADR-014). It was used by the
        // Phase 2/2.5/2.6 spikes, which now live in ../Spike and are not compiled.
        // Phase 6 restores it to benchmark Parakeet properly.
    ],
    targets: [
        // The executable is a thin shell around WhisperingFlowKit so the app's
        // logic can be imported by tests. An executable target's symbols are not
        // visible to a test target.
        .executableTarget(
            name: "WhisperingFlow",
            dependencies: ["WhisperingFlowKit"],
            path: "Sources/WhisperingFlowExecutable",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .target(
            name: "WhisperingFlowKit",
            dependencies: [
                .product(name: "TextProcessingCore", package: "TextProcessingCore"),
                .product(name: "HotkeyGestureCore", package: "HotkeyGestureCore"),
                .product(name: "AudioCaptureCore", package: "AudioCaptureCore"),
            ],
            path: "Sources/WhisperingFlow",
            // No `resources:` on purpose. SwiftPM emits them as a sibling
            // .bundle without an Info.plist, which `codesign --deep` refuses
            // to treat as a signable component. All iconography is SF Symbols,
            // so the target needs no resource files at all.
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .testTarget(
            name: "WhisperingFlowTests",
            dependencies: ["WhisperingFlowKit"],
            path: "Tests/WhisperingFlowTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
