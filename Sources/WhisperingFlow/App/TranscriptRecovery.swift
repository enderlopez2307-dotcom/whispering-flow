import AppKit
import Foundation
import Observation

/// One transcript the user could still want back.
struct RecoverableTranscript: Sendable, Equatable, Identifiable {
    enum Outcome: String, Sendable {
        case inserted
        case insertionFailed
        case blocked
        case pending
    }

    let id: UUID
    let text: String
    let capturedAt: Date
    let locale: String
    var outcome: Outcome
    var failureDetail: String?

    var isRecoverable: Bool { outcome != .inserted }
}

/// **ADR-015: dictated text must never be silently lost.**
///
/// Every transcript is recorded here the moment it is finalised — *before*
/// insertion is attempted — because every measured failure mode happens
/// downstream of transcription: paste landing in the wrong field, Secure Input
/// refusing paste with no error, or an app that takes no text at all. Losing
/// words the app heard correctly is the worst outcome it can produce.
///
/// Kept in memory only, and bounded. Persisting transcripts to disk would widen
/// the privacy surface for a feature whose whole point is that nothing leaves
/// the machine.
@MainActor
@Observable
final class TranscriptRecovery {

    private(set) var history: [RecoverableTranscript] = []
    private let limit: Int

    init(limit: Int = 10) {
        self.limit = limit
    }

    var latest: RecoverableTranscript? { history.first }

    /// Most recent transcript that never made it into an app.
    var latestUnrecovered: RecoverableTranscript? {
        history.first { $0.isRecoverable }
    }

    /// Record a transcript. Call this **before** attempting insertion.
    @discardableResult
    func record(text: String, locale: String) -> UUID {
        let entry = RecoverableTranscript(
            id: UUID(), text: text, capturedAt: Date(),
            locale: locale, outcome: .pending, failureDetail: nil)
        history.insert(entry, at: 0)
        if history.count > limit { history.removeLast(history.count - limit) }
        Log.recovery.info("recorded transcript \(entry.id.uuidString, privacy: .public) (\(text.count) chars)")
        return entry.id
    }

    func markOutcome(_ id: UUID, _ outcome: RecoverableTranscript.Outcome, detail: String? = nil) {
        guard let index = history.firstIndex(where: { $0.id == id }) else { return }
        history[index].outcome = outcome
        history[index].failureDetail = detail
        Log.recovery.info("transcript \(id.uuidString, privacy: .public) -> \(outcome.rawValue, privacy: .public)")
    }

    /// Put a transcript on the pasteboard so the user can place it by hand.
    /// This is the escape hatch the invariant exists to guarantee.
    ///
    /// `pasteboard` is injectable so the test can assert the markers without
    /// clobbering the real clipboard of whoever is running the suite.
    @discardableResult
    func copyToPasteboard(_ id: UUID, to pasteboard: NSPasteboard = .general) -> Bool {
        guard let entry = history.first(where: { $0.id == id }) else { return false }
        // Same transient/concealed markers as the paste inserter, not a bare
        // `setString`. This path matters more, not less: it is reached exactly
        // when insertion was refused — caret in a password field, in window
        // chrome, or the user switched apps — so the transcripts most likely to
        // travel it are the most sensitive ones, and unlike the paste path the
        // text stays on the clipboard until something else replaces it.
        let before = pasteboard.changeCount
        let after = ClipboardPasteInserter.writeTransient(entry.text, to: pasteboard)
        let ok = after != before && pasteboard.string(forType: .string) == entry.text
        Log.recovery.info("copied transcript to pasteboard: \(ok, privacy: .public)")
        return ok
    }

    func clear() {
        history.removeAll()
        Log.recovery.info("history cleared")
    }
}
