import Foundation

/// The push-to-talk state machine. Pure and synchronous.
///
/// Time arrives *on the event* and the hold deadline is expressed as an
/// instruction to the caller rather than a timer owned here, so every threshold
/// behaviour is testable deterministically with no clock and no sleeping.
///
/// ```
/// idle ──trigger down──▶ pendingHold ──threshold──▶ active ──release──▶ end
///   ▲   (triggerPressed)     │                        │
///   └──release before────────┘                        └──Escape──▶ cancel
///      threshold → cancel
///      (accidental tap: no begin, no end, capture discarded)
/// ```
///
/// **Hands-free (double-tap).** Additive to the hold gesture, never a
/// replacement (ADR-016 keeps hold-to-talk the default). A clean tap that is
/// released before the threshold is remembered for `doubleTapWindow`; a second
/// press inside that window locks a session open — `begin` fires on that second
/// press and the release is ignored. The next press ends it, Escape cancels it,
/// and a hard `handsFreeLimit` ends it so an abandoned session cannot leave the
/// microphone open. A tap that was part of a shortcut (any other key went down
/// while it was held, e.g. ⌘C then ⌘V with Right Command) is never a tap.
///
/// ```
/// idle ─tap─▶ awaitingSecondTap ─press within window─▶ handsFree ─press─▶ end
///                  │ window passes / any key                 └─Escape / limit
///                  ▼
///                idle
/// ```
///
/// **`begin` fires when the threshold elapses, not on the physical press.** That
/// is what stops an accidental modifier tap becoming a dictation, and it is a
/// deliberate change from the Phase 2 spike, which began immediately. The cost
/// is that the first ~150 ms of speech is not captured, so audio capture must
/// keep a pre-roll buffer (Phase 5).
public struct PressGesture: Sendable, Equatable {

    /// What the caller should do. Timer management is the caller's job; this
    /// type only says when to arm and disarm one.
    public enum Intent: Sendable, Equatable {
        /// The physical trigger went down. Emitted immediately, ahead of any
        /// threshold, so audio capture can start filling a pre-roll buffer —
        /// `begin` arrives ~151 ms later and capture that waits for it loses the
        /// first syllable (TECH_RESEARCH §18.1, ADR-018).
        ///
        /// This is provisional: it may be followed by `begin` or by `cancel`,
        /// and nothing durable may be built on it alone.
        case triggerPressed
        case armHoldTimer(deadline: Double)
        case cancelHoldTimer
        case begin
        case end
        /// Discard whatever capture is in flight — an accidental tap that never
        /// reached `begin`, or Escape during a live session. Both mean the same
        /// thing to the audio layer, so they are one intent.
        case cancel
        /// Emitted right after `begin` when a double-tap locked the session
        /// open, so the UI can say "tap to stop" instead of "release to stop".
        case handsFreeLocked
        /// Arm / disarm the hands-free safety limit (the caller owns the timer).
        case armHandsFreeLimit(deadline: Double)
        case cancelHandsFreeLimit
    }

    /// Virtual key code for Escape. The one hard-coded key: cancelling is not
    /// user-rebindable.
    public static let escapeKeyCode: UInt16 = 53

    enum Phase: Sendable, Equatable {
        case idle
        /// Trigger is down; the hold threshold has not yet elapsed.
        case pendingHold(pressedAt: Double)
        /// Session running.
        case active
        /// Escape cancelled an active session and the trigger is still
        /// physically down. Exists so the eventual release does not emit a
        /// spurious `end`.
        case cancelledAwaitingRelease
        /// A clean tap was released; a second press within `doubleTapWindow`
        /// starts a hands-free session.
        case awaitingSecondTap(releasedAt: Double)
        /// Locked-open session. `triggerDown` is true while the second press
        /// that locked it is still physically held.
        case handsFree(triggerDown: Bool)
    }

    public var binding: HotkeyBinding
    public var mode: TriggerMode
    /// How long the trigger must be held before a session starts.
    public var holdThreshold: Double
    /// Whether a double-tap may start a hands-free session. Only honoured in
    /// `.hold` mode; `.toggle` already is hands-free.
    public var handsFreeEnabled: Bool
    /// Max gap between the first tap's release and the second press.
    public var doubleTapWindow: Double
    /// A locked-open session ends by itself after this long (no idle mic).
    public var handsFreeLimit: Double

    private(set) var phase: Phase = .idle
    /// Another key went down while the trigger was held, so this press was a
    /// shortcut chord and not a lone tap.
    private var chordedDuringPress = false

    public init(binding: HotkeyBinding,
                mode: TriggerMode = .hold,
                holdThreshold: Double = 0.15,
                handsFreeEnabled: Bool = false,
                doubleTapWindow: Double = 0.35,
                handsFreeLimit: Double = 300) {
        self.binding = binding
        self.mode = mode
        self.holdThreshold = holdThreshold
        self.handsFreeEnabled = handsFreeEnabled
        self.doubleTapWindow = doubleTapWindow
        self.handsFreeLimit = handsFreeLimit
    }

    public var hasActiveSession: Bool {
        switch phase {
        case .active, .handsFree: true
        default: false
        }
    }

    public var isHandsFree: Bool {
        if case .handsFree = phase { return true }
        return false
    }

    private var doubleTapAllowed: Bool { handsFreeEnabled && mode == .hold }

    /// For diagnostics only.
    public var phaseDescription: String {
        switch phase {
        case .idle: "idle"
        case .pendingHold: "pendingHold"
        case .active: "active"
        case .cancelledAwaitingRelease: "cancelledAwaitingRelease"
        case .awaitingSecondTap: "awaitingSecondTap"
        case .handsFree: "handsFree"
        }
    }
    public var isAwaitingThreshold: Bool {
        if case .pendingHold = phase { return true }
        return false
    }

    // MARK: - Events

    public mutating func handle(_ event: HotkeyEvent) -> [Intent] {
        // Escape cancels an active session regardless of which key is bound.
        if event.kind == .keyDown, event.keyCode == Self.escapeKeyCode, !event.isAutoRepeat {
            switch phase {
            case .active:
                phase = .cancelledAwaitingRelease
                return [.cancel]
            case .pendingHold:
                // No session was ever announced, but provisional capture is
                // running since `triggerPressed`. Disarm and discard it.
                phase = .cancelledAwaitingRelease
                return [.cancelHoldTimer, .cancel]
            case .handsFree(let triggerDown):
                // The trigger is normally up here; only swallow a release if the
                // locking press is still held, or the next real press is eaten.
                phase = triggerDown ? .cancelledAwaitingRelease : .idle
                return [.cancelHandsFreeLimit, .cancel]
            case .awaitingSecondTap:
                phase = .idle
                return []
            case .idle, .cancelledAwaitingRelease:
                return []
            }
        }

        if isChordKey(event) {
            switch phase {
            case .pendingHold: chordedDuringPress = true
            case .awaitingSecondTap: phase = .idle
            default: break
            }
        }

        guard binding.isRelevant(to: event) else { return [] }
        // Auto-repeat must never look like a second press.
        if event.isAutoRepeat { return [] }

        let satisfied = binding.isSatisfied(by: event)
        return satisfied
            ? handleTriggerDown(at: event.timestamp)
            : handleTriggerUp(at: event.timestamp)
    }

    /// A key other than the trigger and Escape went down.
    private func isChordKey(_ event: HotkeyEvent) -> Bool {
        guard event.kind == .keyDown, !event.isAutoRepeat,
              event.keyCode != Self.escapeKeyCode else { return false }
        if case .key(let boundKeyCode, _) = binding { return event.keyCode != boundKeyCode }
        return true
    }

    /// Called by the owner when the hands-free safety limit fires. Ends (does
    /// not cancel) the session, so what was said is still transcribed.
    public mutating func handsFreeLimitElapsed() -> [Intent] {
        guard case .handsFree(let triggerDown) = phase else { return [] }
        phase = triggerDown ? .cancelledAwaitingRelease : .idle
        return [.end]
    }

    /// Called by the owner when the armed hold timer fires.
    ///
    /// Returns nothing unless the gesture is still waiting — a release that
    /// happened first will already have disarmed it, and a late timer must not
    /// resurrect a session.
    public mutating func holdThresholdElapsed(at timestamp: Double) -> [Intent] {
        guard case .pendingHold(let pressedAt) = phase else { return [] }
        guard timestamp - pressedAt >= holdThreshold - 0.001 else { return [] }
        if chordedDuringPress {
            // Another key went down while the trigger was held: the user is
            // using it as a modifier (⌘C, ⌘V with Right Command held a beat
            // long), not asking to dictate. Discard the pre-roll and swallow
            // the eventual release. A press held past the threshold used to
            // begin regardless, so a slow ⌘V flashed the HUD and ran a
            // pointless dictation.
            phase = .cancelledAwaitingRelease
            return [.cancel]
        }
        phase = .active
        return [.begin]
    }

    // MARK: - Transitions

    private mutating func handleTriggerDown(at timestamp: Double) -> [Intent] {
        switch phase {
        case .idle:
            return startPress(at: timestamp)

        case .awaitingSecondTap(let releasedAt):
            guard doubleTapAllowed, timestamp - releasedAt <= doubleTapWindow else {
                // Window passed: this is a fresh first press, not a second tap.
                return startPress(at: timestamp)
            }
            phase = .handsFree(triggerDown: true)
            return [.triggerPressed, .begin, .handsFreeLocked,
                    .armHandsFreeLimit(deadline: timestamp + handsFreeLimit)]

        case .handsFree(let triggerDown):
            // A repeated flagsChanged for a modifier that is still down.
            guard !triggerDown else { return [] }
            // A press while locked open is the stop gesture. Swallow its release.
            phase = .cancelledAwaitingRelease
            return [.cancelHandsFreeLimit, .end]

        case .active where mode == .toggle:
            // In toggle mode a second press stops the session. No threshold:
            // once running, the user's intent to stop is unambiguous.
            phase = .idle
            return [.end]

        case .pendingHold, .active, .cancelledAwaitingRelease:
            // Already engaged. Guards duplicate begins from repeated
            // flagsChanged events carrying the same modifier still down.
            return []
        }
    }

    private mutating func startPress(at timestamp: Double) -> [Intent] {
        chordedDuringPress = false
        phase = .pendingHold(pressedAt: timestamp)
        return [.triggerPressed, .armHoldTimer(deadline: timestamp + holdThreshold)]
    }

    private mutating func handleTriggerUp(at timestamp: Double) -> [Intent] {
        switch phase {
        case .pendingHold:
            // Released before the threshold: a tap. No begin was ever emitted,
            // so no end may be either — but `triggerPressed` already started
            // provisional capture, so it must be discarded. A clean tap is
            // remembered as the possible first half of a double-tap.
            phase = (doubleTapAllowed && !chordedDuringPress)
                ? .awaitingSecondTap(releasedAt: timestamp)
                : .idle
            return [.cancelHoldTimer, .cancel]

        case .handsFree(let triggerDown):
            // Release of the locking press: the session stays open.
            if triggerDown { phase = .handsFree(triggerDown: false) }
            return []

        case .awaitingSecondTap:
            return []

        case .active:
            if mode == .toggle {
                // Releasing does not stop a toggle session.
                return []
            }
            phase = .idle
            return [.end]

        case .cancelledAwaitingRelease:
            // The session was already cancelled; swallow the release.
            phase = .idle
            return []

        case .idle:
            // Release with no matching press — stray event, ignore.
            return []
        }
    }

    /// Drop all transient state. Call when the binding or mode changes, or when
    /// the event tap is re-armed, so a half-finished gesture cannot persist
    /// across a reconfiguration.
    public mutating func reset() {
        phase = .idle
        chordedDuringPress = false
    }
}
