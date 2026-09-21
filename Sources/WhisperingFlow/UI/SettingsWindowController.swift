import AppKit
import SwiftUI

/// Hosts `SettingsView` in a single reusable window.
///
/// An accessory app has no menu bar of its own, so the window has to be brought
/// forward explicitly — and the app briefly becomes `.regular` while it is open,
/// otherwise the window cannot take focus or be dismissed with ⌘W.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private let makeContent: () -> AnyView

    init(content: @escaping () -> AnyView) {
        self.makeContent = content
        super.init()
    }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: makeContent())
            let window = NSWindow(contentViewController: hosting)
            window.title = "Whispering Flow Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        Log.app.info("settings window shown")
    }

    /// Drop back to accessory so the app leaves the Dock and the app switcher
    /// again once settings close.
    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Log.app.info("settings window closed")
    }
}
