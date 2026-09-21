// swift-tools-version: 6.2
import PackageDescription

// Pure push-to-talk gesture interpretation. Consumes value-type key events
// and emits intents. No CGEventTap, no AppKit — so the fiddliest logic in the
// app (auto-repeat, hold-vs-toggle, stuck modifiers) is testable in isolation.
let package = Package(
    name: "HotkeyGestureCore",
    platforms: [.macOS(.v26)],
    products: [.library(name: "HotkeyGestureCore", targets: ["HotkeyGestureCore"])],
    targets: [
        .target(
            name: "HotkeyGestureCore",
            swiftSettings: [.swiftLanguageMode(.v6), .enableUpcomingFeature("ExistentialAny")]
        ),
        .testTarget(
            name: "HotkeyGestureCoreTests",
            dependencies: ["HotkeyGestureCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
