import Foundation

/// What the status item shows. Derived from `SessionState`; kept separate so the
/// icon vocabulary can change without touching the state machine.
enum MenuBarState: Equatable, Sendable {
    case idle
    case listening
    case working          // transcribing / processing / inserting
    case blocked
    case failed
    /// Smart mode silently fell back to the Fast result on the last dictation.
    /// Shown until the menu is opened, so the user finds out it happened
    /// instead of experiencing "Smart does nothing sometimes".
    case smartSkipped

    init(session: SessionState) {
        switch session {
        case .idle: self = .idle
        case .listening: self = .listening
        case .transcribing, .processing, .inserting: self = .working
        case .blocked: self = .blocked
        case .failed: self = .failed
        }
    }

    /// SF Symbol name. No bundled image assets — that is what let the SwiftPM
    /// resource-bundle vs `codesign --deep` problem be avoided entirely (ADR-012).
    var symbolName: String {
        switch self {
        case .idle: "mic"
        case .listening: "mic.fill"
        case .working: "waveform"
        case .blocked: "mic.slash"
        case .failed: "exclamationmark.triangle"
        case .smartSkipped: "text.badge.xmark"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .idle: "Whispering Flow — ready"
        case .listening: "Whispering Flow — listening"
        case .working: "Whispering Flow — working"
        case .blocked: "Whispering Flow — blocked"
        case .failed: "Whispering Flow — last dictation failed"
        case .smartSkipped: "Whispering Flow — Smart cleanup was skipped on the last dictation"
        }
    }
}
