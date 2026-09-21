import Foundation

/// The three grants this app cannot work without (ARCHITECTURE §3.8).
enum Permission: String, Sendable, CaseIterable {
    case microphone      = "Microphone"
    case accessibility   = "Accessibility"
    case inputMonitoring = "Input Monitoring"

    /// The System Settings pane that grants it.
    public var settingsURL: URL {
        let anchor = switch self {
        case .microphone:      "Privacy_Microphone"
        case .accessibility:   "Privacy_Accessibility"
        case .inputMonitoring: "Privacy_ListenEvent"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }

    /// Why we need it, in the user's terms.
    public var rationale: String {
        switch self {
        case .microphone:
            "To hear you when you hold the dictation key."
        case .accessibility:
            "To place the finished text where your cursor is."
        case .inputMonitoring:
            "To notice when you press and release the dictation key."
        }
    }
}

enum PermissionStatus: String, Sendable, Equatable {
    case granted
    case denied
    case notDetermined

    public var isGranted: Bool { self == .granted }

    public var symbol: String {
        switch self {
        case .granted:       "GRANTED"
        case .denied:        "DENIED"
        case .notDetermined: "NOT DETERMINED"
        }
    }
}
