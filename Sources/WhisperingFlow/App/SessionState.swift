import Foundation

/// Why the app currently cannot dictate.
enum BlockReason: Equatable, Sendable {
    case missingPermissions([Permission])
    case secureInput(holder: String?)

    var title: String {
        switch self {
        case .missingPermissions(let permissions):
            permissions.count == 1
                ? "\(permissions[0].rawValue) permission needed"
                : "\(permissions.count) permissions needed"
        case .secureInput:
            "Secure input is active"
        }
    }

    var detail: String {
        switch self {
        case .missingPermissions(let permissions):
            permissions.map(\.rationale).joined(separator: " ")
        case .secureInput(let holder):
            if let holder {
                "\(holder) is holding secure input. No app can see the keyboard shortcut until it stops."
            } else {
                "Another app is holding secure input. No app can see the keyboard shortcut until it stops."
            }
        }
    }
}

/// Why the last attempt failed. Every case names something actionable —
/// silence is a bug (ARCHITECTURE §1).
enum FailureReason: Equatable, Sendable {
    case audioUnavailable(String)
    case transcriptionFailed(String)
    case noSpeechDetected
    case insertionFailed(String)

    var title: String {
        switch self {
        case .audioUnavailable: "Microphone unavailable"
        case .transcriptionFailed: "Could not transcribe"
        case .noSpeechDetected: "No speech detected"
        case .insertionFailed: "Could not insert text"
        }
    }

    var detail: String {
        switch self {
        case .audioUnavailable(let detail): detail
        case .transcriptionFailed(let detail): detail
        case .noSpeechDetected: "Nothing was inserted."
        case .insertionFailed(let detail): detail
        }
    }

    /// Whether a transcript may still be recoverable after this failure.
    /// Drives whether the menu offers "Copy Last Transcript" (ADR-015).
    var mayHaveTranscript: Bool {
        switch self {
        case .insertionFailed: true
        case .audioUnavailable, .transcriptionFailed, .noSpeechDetected: false
        }
    }
}

/// The dictation state machine's state. One press-to-insert cycle walks
/// idle → listening → transcribing → processing → inserting → idle.
enum SessionState: Equatable, Sendable {
    case idle
    case listening(startedAt: Date)
    case transcribing
    case processing
    case inserting
    case blocked(BlockReason)
    case failed(FailureReason)

    var isBusy: Bool {
        switch self {
        case .listening, .transcribing, .processing, .inserting: true
        case .idle, .blocked, .failed: false
        }
    }

    /// A new session may only start from a state that is not mid-flight and not
    /// blocked. `.failed` is startable — a previous failure must not wedge the app.
    var canStartSession: Bool {
        switch self {
        case .idle, .failed: true
        case .listening, .transcribing, .processing, .inserting, .blocked: false
        }
    }
}
