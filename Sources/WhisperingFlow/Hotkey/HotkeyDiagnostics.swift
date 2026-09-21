import Foundation

/// Observable health of the event tap.
///
/// `isRunning` says only that `CGEvent.tapCreate` succeeded. It does **not**
/// mean events are arriving — with a stale Input Monitoring grant the tap goes
/// live and then stays silent forever, which is indistinguishable in a log from
/// "the user never pressed anything". That ambiguity cost a debugging session in
/// Phase 2 (TECH_RESEARCH §15.7), so the two are separate signals here.
struct HotkeyDiagnostics: Sendable, Equatable {
    var isTapInstalled = false
    var hasReceivedAnyEvent = false
    /// How many times a `CGEventTap` has actually been created. Must stay at 1
    /// for the life of the process: recovery re-enables the existing port, and a
    /// second creation would mean two taps delivering duplicate events.
    var tapCreatedCount = 0
    var eventCount = 0
    var matchedTriggerCount = 0
    var sessionsBegun = 0
    var sessionsEnded = 0
    var sessionsCancelled = 0
    /// Sub-threshold taps whose provisional capture was thrown away.
    var tapsDiscarded = 0
    var tapDisabledCount = 0
    var tapReenabledCount = 0
    var lastEventAt: Date?

    /// The distinction that matters when the hotkey "does not work".
    enum Health: Equatable, Sendable {
        case notStarted
        /// Tap created but no event has ever arrived — almost always a stale or
        /// missing Input Monitoring grant, or Secure Input.
        case installedButSilent
        /// Events flow but none match the configured binding — the user is
        /// pressing the wrong key, or the binding is wrong.
        case receivingButUnmatched
        case working
    }

    var health: Health {
        guard isTapInstalled else { return .notStarted }
        guard hasReceivedAnyEvent else { return .installedButSilent }
        return matchedTriggerCount > 0 ? .working : .receivingButUnmatched
    }

    var summary: String {
        switch health {
        case .notStarted:
            "Event tap not installed."
        case .installedButSilent:
            "Event tap installed but no keyboard events have arrived. "
            + "Input Monitoring is most likely missing or stale, or secure input is active."
        case .receivingButUnmatched:
            "Receiving keyboard events (\(eventCount)) but none matched the configured shortcut."
        case .working:
            "Working — \(matchedTriggerCount) trigger events, \(sessionsBegun) sessions."
        }
    }
}
