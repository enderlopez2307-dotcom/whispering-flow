import AppKit
import Foundation

/// Delivers final text to the cursor, or declines and says why.
///
/// The chain's first step is not a strategy at all — it is a **refusal check**.
/// The Phase 2 spike proved that a successful ⌘V says nothing about where the
/// text landed, so the destination is inspected before anything is delivered
/// and re-checked at delivery time (ADR-006 amendment, ADR-023).
///
/// Declining to insert is a good outcome. Writing a dictated sentence into an
/// address bar, a password field, or the app the user just switched to is
/// strictly worse than inserting nothing and offering the text back.
@MainActor
final class InsertionChain: TextInserting {

    private let strategies: [any InsertionStrategy]
    /// Captured when dictation begins, so a mid-dictation app switch is
    /// detectable rather than silently obeyed.
    private var intendedTarget: FocusedTarget?

    private(set) var diagnostics = InsertionDiagnostics()

    init(strategies: [any InsertionStrategy] = [
        AccessibilityInserter(),
        ClipboardPasteInserter(),
        UnicodeKeystrokeInserter(),
    ]) {
        self.strategies = strategies
    }

    /// Called at the start of dictation. What the user was looking at when they
    /// pressed the key is the only honest definition of "the intended target".
    func captureIntendedTarget() {
        let target = FocusedAppProbe.current()
        intendedTarget = target
        Log.insertion.info("intended target: \(target.applicationName ?? "unknown", privacy: .public) role=\(target.role ?? "—", privacy: .public) subrole=\(target.subrole ?? "—", privacy: .public)")
    }

    func insert(_ text: String) async -> InsertionOutcome {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failed(reason: "nothing to insert")
        }
        // Never. Dictation inserts text; the user decides when to send.
        // Especially in Terminal, Claude Code, ChatGPT and Gmail, where a
        // stray Return executes or sends something irreversible.
        assert(!text.hasSuffix("\n") || text.hasSuffix("\n\n"),
               "a single trailing newline would submit in some targets")

        let current = intendedTarget.map { FocusedAppProbe.verify($0) } ?? FocusedAppProbe.current()
        diagnostics.lastTargetDescription =
            "\(current.applicationName ?? "?") \(current.role ?? "—")/\(current.subrole ?? "—")"
        let where_ = diagnostics.lastTargetDescription ?? "?"
        Log.insertion.info("delivering to \(where_, privacy: .public) — \(String(describing: current.confidence), privacy: .public)")

        guard current.allowsInsertion else {
            let reason = current.refusalReason ?? "The cursor is not somewhere text can go."
            diagnostics.refusals += 1
            Log.insertion.info("refused: \(reason, privacy: .public)")
            return .refused(reason: reason)
        }

        var lastFailure = "no strategy could deliver the text"
        for strategy in strategies where strategy.canAttempt(current) {
            let started = Date()
            let outcome = await strategy.insert(text, into: current)
            let elapsed = Date().timeIntervalSince(started) * 1000

            switch outcome {
            case .inserted(let name):
                diagnostics.record(strategy: name, milliseconds: elapsed)
                Log.insertion.info("inserted via \(name, privacy: .public) in \(Int(elapsed), privacy: .public) ms")
                return outcome
            case .refused(let reason):
                // A refusal is terminal: secure input will block every strategy,
                // so trying the next one just wastes time and posts more events.
                diagnostics.refusals += 1
                Log.insertion.info("refused by \(strategy.name, privacy: .public): \(reason, privacy: .public)")
                return outcome
            case .failed(let reason):
                lastFailure = reason
                diagnostics.strategyFailures += 1
                Log.insertion.info("\(strategy.name, privacy: .public) failed: \(reason, privacy: .public) — trying the next")
            }
        }
        Log.insertion.error("all strategies failed: \(lastFailure, privacy: .public)")
        return .failed(reason: lastFailure)
    }
}

/// Counts and timings. Never inserted text.
struct InsertionDiagnostics: Sendable, Equatable {
    var byStrategy: [String: Int] = [:]
    var lastStrategy: String?
    var lastMilliseconds: Double = 0
    var refusals = 0
    var strategyFailures = 0
    var lastTargetDescription: String?

    mutating func record(strategy: String, milliseconds: Double) {
        byStrategy[strategy, default: 0] += 1
        lastStrategy = strategy
        lastMilliseconds = milliseconds
    }

    var summary: String {
        let counts = byStrategy.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        return "insert: \(counts.isEmpty ? "none" : counts)"
            + " last=\(lastStrategy ?? "—") \(Int(lastMilliseconds))ms"
            + " refused=\(refusals) failed=\(strategyFailures)"
    }
}
