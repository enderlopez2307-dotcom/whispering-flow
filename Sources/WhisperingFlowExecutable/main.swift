import AppKit
import WhisperingFlowKit

// Thin shell. Everything lives in WhisperingFlowKit so it can be unit-tested —
// an executable target's symbols are not importable by a test target.
MainActor.assumeIsolated {
    if DiagnosticsCommand.runIfRequested() { exit(0) }

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // .accessory: no Dock icon, no app menu, never becomes active on launch.
    // LSUIElement in Info.plist says the same declaratively; both are set so the
    // behaviour holds whether launched via Finder or execve.
    app.setActivationPolicy(.accessory)
    app.run()
}
