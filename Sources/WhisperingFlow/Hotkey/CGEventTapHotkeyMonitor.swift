import AppKit
import CoreGraphics
import Foundation
import HotkeyGestureCore
import Observation

/// Production global push-to-talk monitor.
///
/// Owns a session-level `CGEventTap`, converts raw events into the minimum
/// value type the pure gesture machine needs, and emits only semantic
/// `begin` / `end` / `cancel`. Nothing above this type knows that CoreGraphics
/// exists.
///
/// **The tap is `.listenOnly` and suppresses nothing.** Right Command is a real
/// system modifier; swallowing it would break ⌘C, ⌘V, ⌘Tab and every other
/// shortcut. Observing without consuming is the only safe posture for a binding
/// that doubles as a modifier.
@MainActor
@Observable
final class CGEventTapHotkeyMonitor: HotkeyMonitoring {

    var onTriggerPressed: (() -> Void)?
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onCancel: (() -> Void)?
    /// Fired right after `onPress` when a double-tap locked the session open.
    var onHandsFreeLocked: (() -> Void)?

    private(set) var diagnostics = HotkeyDiagnostics()
    var isRunning: Bool { diagnostics.isTapInstalled }
    var hasReceivedAnyEvent: Bool { diagnostics.hasReceivedAnyEvent }

    /// Latency samples, for the Phase 4 measurement requirement. Bounded.
    private(set) var pressToBeginSamples: [Double] = []
    private(set) var releaseToEndSamples: [Double] = []
    /// Physical press → the pre-roll handler returned. Bounds how much audio the
    /// pre-roll can possibly be missing.
    private(set) var pressToCaptureSamples: [Double] = []

    /// True between `begin` and `end`/`cancel`. Distinguishes a cancelled
    /// session from a discarded accidental tap, which share the `.cancel` intent.
    private var isSessionOpen = false

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// Not private so tests can assert the gesture phase after a tap reset.
    private(set) var gesture: PressGesture
    private var holdTimer: Timer?
    /// Ends a hands-free session that was never stopped, so an abandoned one
    /// cannot leave the microphone open.
    private var handsFreeLimitTimer: Timer?

    /// Set while a hold is pending so the begin latency can be measured against
    /// the physical press rather than the timer's nominal deadline.
    private var pendingPressUptime: Double?

    private let holdThreshold: Double

    /// `--trace-hotkey`: log every modifier transition the tap sees.
    ///
    /// Modifier *names* only — never key codes, never characters. The tap sees
    /// every keystroke on the system including passwords, so the trace is
    /// deliberately incapable of reconstructing what was typed.
    private let isTracing = ProcessInfo.processInfo.arguments.contains("--trace-hotkey")

    /// Monotonic clock, injected so the latency arithmetic can be asserted
    /// exactly instead of being smoke-tested against a real stopwatch.
    private let now: @MainActor @Sendable () -> Double

    init(binding: HotkeyBinding = Preferences.default.hotkey,
         triggerMode: TriggerMode = .hold,
         holdThreshold: Double = 0.15,
         handsFree: Bool = false,
         handsFreeLimit: Double = HandsFreeLimit.seconds,
         now: @escaping @MainActor @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.holdThreshold = holdThreshold
        self.now = now
        self.gesture = PressGesture(binding: binding, mode: triggerMode, holdThreshold: holdThreshold,
                                    handsFreeEnabled: handsFree, handsFreeLimit: handsFreeLimit)
    }

    // MARK: - Lifecycle

    func start() throws {
        guard tap == nil else { return }
        try installTap()
        Log.hotkey.info("event tap started — watching \(self.gesture.binding.displayName, privacy: .public)")
    }

    func stop() {
        abandonInFlightSession(reason: "monitor stopped")
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        diagnostics.isTapInstalled = false
        Log.hotkey.info("event tap stopped")
    }

    /// Rebind at runtime. The tap stays installed; only the per-event filter
    /// changes, so there is never a window with two taps or none.
    func update(binding: HotkeyBinding, triggerMode: TriggerMode, handsFree: Bool) {
        guard binding != gesture.binding || triggerMode != gesture.mode
                || handsFree != gesture.handsFreeEnabled else { return }
        abandonInFlightSession(reason: "rebound")
        gesture.binding = binding
        gesture.mode = triggerMode
        gesture.handsFreeEnabled = handsFree
        gesture.reset()
        Log.hotkey.info("binding -> \(binding.displayName, privacy: .public) / \(triggerMode.rawValue, privacy: .public) / handsFree \(handsFree, privacy: .public)")
    }

    // MARK: - Tap

    private func installTap() throws {
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        let opaque = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            // .listenOnly: never consume an event. See the type comment.
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: tapCallback,
            userInfo: opaque
        ) else {
            diagnostics.isTapInstalled = false
            throw HotkeyMonitorError.tapCreationFailed
        }

        self.tap = tap
        diagnostics.tapCreatedCount += 1
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.runLoopSource = source
        diagnostics.isTapInstalled = true
    }

    /// Re-arm after macOS disables the tap.
    ///
    /// The system disables a tap whose callback runs too long
    /// (`.tapDisabledByTimeout`) or on user input events. A tap that dies
    /// silently is the classic "my hotkey randomly stopped working" bug, so this
    /// re-enables the existing port rather than creating a second one — creating
    /// one would leave two taps delivering duplicate events.
    func handleTapDisabled(reason: String) {
        diagnostics.tapDisabledCount += 1
        Log.hotkey.error("event tap disabled (\(reason, privacy: .public)) — re-enabling")
        abandonInFlightSession(reason: "tap disabled")

        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
        diagnostics.tapReenabledCount += 1
        Log.hotkey.info("event tap re-enabled (total \(self.diagnostics.tapReenabledCount, privacy: .public))")
    }

    /// Drop any gesture, timer and audio still in flight, and tell the
    /// coordinator if a session was actually open.
    ///
    /// Resetting the gesture alone is not enough. A locked-open hands-free
    /// session lives in the gesture *and* in the coordinator, so a bare
    /// `gesture.reset()` left the coordinator in `.listening` with the
    /// microphone open, the safety timer cancelled, and no gesture able to end
    /// it — every later press was ignored as "session in flight" until the app
    /// was relaunched. Rebinding from Settings did exactly that.
    private func abandonInFlightSession(reason: String) {
        cancelHoldTimer()
        cancelHandsFreeLimitTimer()
        gesture.reset()
        guard isSessionOpen || pendingPressUptime != nil else { return }
        isSessionOpen = false
        pendingPressUptime = nil
        Log.hotkey.info("session dropped — \(reason, privacy: .public)")
        onCancel?()
    }

    // MARK: - Event handling

    /// Called on the main run loop from the tap callback.
    ///
    /// Receives only a value snapshot — never the `CGEvent` — so nothing that
    /// could carry typed characters escapes the callback.
    func handle(snapshot: HotkeyEvent) {
        if !diagnostics.hasReceivedAnyEvent {
            diagnostics.hasReceivedAnyEvent = true
            Log.hotkey.info("first event received — tap is live")
        }
        diagnostics.eventCount += 1
        diagnostics.lastEventAt = Date()

        if isTracing, snapshot.kind == .flagsChanged {
            let names = snapshot.modifiers.displayNames
            Log.hotkey.info("trace flagsChanged [\(names.isEmpty ? "none" : names.joined(separator: ","), privacy: .public)] phase=\(String(describing: self.gesture.phaseDescription), privacy: .public)")
        }

        let wasRelevant = gesture.binding.isRelevant(to: snapshot)
        let intents = gesture.handle(snapshot)
        if wasRelevant && gesture.binding.isSatisfied(by: snapshot) {
            diagnostics.matchedTriggerCount += 1
        }
        for intent in intents { apply(intent, at: snapshot.timestamp) }
    }

    private func apply(_ intent: PressGesture.Intent, at timestamp: Double) {
        switch intent {
        case .triggerPressed:
            // Synchronous on purpose: the measurement below is only meaningful
            // if capture has actually started by the time it is taken.
            onTriggerPressed?()
            record(&pressToCaptureSamples, (currentUptime() - timestamp) * 1000)

        case .armHoldTimer(let deadline):
            pendingPressUptime = timestamp
            // Interval measured from **now**, not from the event timestamp.
            //
            // `.triggerPressed` is handled first and synchronously starts audio
            // capture, which costs ~53 ms. Arming for `deadline - timestamp`
            // therefore fired 53 ms late and pushed press→begin from the
            // measured 151 ms to 199–209 ms, silently changing the hold
            // threshold that ADR-016 locked.
            armHoldTimer(after: max(0, deadline - currentUptime()))

        case .cancelHoldTimer:
            cancelHoldTimer()
            pendingPressUptime = nil

        case .begin:
            cancelHoldTimer()
            var latency = -1.0
            if let pressed = pendingPressUptime {
                latency = (currentUptime() - pressed) * 1000
                record(&pressToBeginSamples, latency)
            }
            pendingPressUptime = nil
            diagnostics.sessionsBegun += 1
            isSessionOpen = true
            Log.hotkey.info("session begin — press→begin \(Self.rounded(latency), privacy: .public) ms")
            onPress?()

        case .handsFreeLocked:
            Log.hotkey.info("hands-free locked — tap \(self.gesture.binding.displayName, privacy: .public) to stop, Escape to cancel")
            onHandsFreeLocked?()

        case .armHandsFreeLimit(let deadline):
            armHandsFreeLimitTimer(after: max(0, deadline - currentUptime()))

        case .cancelHandsFreeLimit:
            cancelHandsFreeLimitTimer()

        case .end:
            cancelHandsFreeLimitTimer()
            let latency = (currentUptime() - timestamp) * 1000
            record(&releaseToEndSamples, latency)
            diagnostics.sessionsEnded += 1
            isSessionOpen = false
            Log.hotkey.info("session end — release→end \(Self.rounded(latency), privacy: .public) ms")
            onRelease?()

        case .cancel:
            cancelHoldTimer()
            cancelHandsFreeLimitTimer()
            pendingPressUptime = nil
            if isSessionOpen {
                diagnostics.sessionsCancelled += 1
                isSessionOpen = false
                Log.hotkey.info("session cancelled")
            } else {
                // An accidental tap. Not a cancelled session — it only means
                // the provisional pre-roll capture must be thrown away.
                diagnostics.tapsDiscarded += 1
                Log.hotkey.info("tap below threshold — pre-roll discarded")
            }
            onCancel?()
        }
    }

    // MARK: - Hold timer

    /// Test hook: the interval the hold timer was actually armed for.
    var onHoldTimerArmedForTesting: ((TimeInterval) -> Void)?

    private func armHoldTimer(after interval: TimeInterval) {
        onHoldTimerArmedForTesting?(interval)
        cancelHoldTimer()
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.holdTimerFired() }
        }
        // No tolerance: this timer defines the feel of the interaction.
        timer.tolerance = 0
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }

    private func cancelHoldTimer() {
        holdTimer?.invalidate()
        holdTimer = nil
    }

    private func holdTimerFired() {
        holdTimer = nil
        let firedAt = currentUptime()
        for intent in gesture.holdThresholdElapsed(at: firedAt) {
            apply(intent, at: firedAt)
        }
    }

    // MARK: - Hands-free limit

    private func armHandsFreeLimitTimer(after interval: TimeInterval) {
        cancelHandsFreeLimitTimer()
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.handsFreeLimitFired() }
        }
        RunLoop.main.add(timer, forMode: .common)
        handsFreeLimitTimer = timer
    }

    private func cancelHandsFreeLimitTimer() {
        handsFreeLimitTimer?.invalidate()
        handsFreeLimitTimer = nil
    }

    private func handsFreeLimitFired() {
        handsFreeLimitTimer = nil
        Log.hotkey.info("hands-free limit reached — ending session")
        for intent in gesture.handsFreeLimitElapsed() {
            apply(intent, at: currentUptime())
        }
    }

    func fireHandsFreeLimitForTesting() {
        handsFreeLimitFired()
    }

    // MARK: - Helpers

    private func currentUptime() -> Double { now() }

    /// Two decimal places. `release→end` is routinely under 100 µs, which whole
    /// milliseconds reported as a flat "0 ms".
    static func rounded(_ value: Double) -> Double { (value * 100).rounded() / 100 }

    private func record(_ samples: inout [Double], _ value: Double) {
        samples.append(value)
        if samples.count > 200 { samples.removeFirst(samples.count - 200) }
    }

    /// Percentile over the recorded samples, nearest-rank. Nil when there are
    /// too few samples for the percentile to mean anything.
    static func percentile(_ samples: [Double], _ p: Double) -> Double? {
        guard samples.count >= Int((1 / (1 - p)).rounded(.up)) else { return nil }
        let sorted = samples.sorted()
        let rank = max(1, Int((p * Double(sorted.count)).rounded(.up)))
        return sorted[rank - 1]
    }

    /// One line of numbers for the debug menu and the support log. Contains no
    /// key codes and no text — only counts and milliseconds.
    var latencySummary: String {
        func describe(_ label: String, _ samples: [Double]) -> String {
            guard !samples.isEmpty else { return "\(label): no samples" }
            let p50 = Self.percentile(samples, 0.50).map { "\(Self.rounded($0))" } ?? "—"
            let p95 = Self.percentile(samples, 0.95).map { "\(Self.rounded($0))" } ?? "—"
            return "\(label): n=\(samples.count) p50=\(p50)ms p95=\(p95)ms"
        }
        return describe("press→begin", pressToBeginSamples)
            + "  |  " + describe("release→end", releaseToEndSamples)
            + "  |  threshold=\(Int(holdThreshold * 1000))ms"
    }

    /// Test and debug hook: drive the gesture without a physical key.
    func injectForTesting(_ event: HotkeyEvent) {
        handle(snapshot: event)
    }

    func fireHoldTimerForTesting() {
        holdTimerFired()
    }
}

enum HotkeyMonitorError: LocalizedError {
    case tapCreationFailed

    var errorDescription: String? {
        switch self {
        case .tapCreationFailed:
            "Could not create the keyboard event tap. Input Monitoring permission is "
            + "most likely missing, or another app is holding secure input."
        }
    }
}

/// C callback. Deliberately minimal: no allocation beyond the snapshot, no
/// locks, no logging, and **no key codes for anything except the bound key** —
/// this sees every keystroke on the system, including passwords.
private let tapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<CGEventTapHotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        let reason = type == .tapDisabledByTimeout ? "timeout" : "user input"
        MainActor.assumeIsolated { monitor.handleTapDisabled(reason: reason) }
        return Unmanaged.passUnretained(event)
    }

    let kind: HotkeyEvent.Kind? = switch type {
    case .keyDown: .keyDown
    case .keyUp: .keyUp
    case .flagsChanged: .flagsChanged
    default: nil
    }
    guard let kind else { return Unmanaged.passUnretained(event) }

    let snapshot = HotkeyEvent(
        kind: kind,
        keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)),
        modifiers: ModifierFlagMapping.modifiers(from: event.flags.rawValue),
        isAutoRepeat: kind == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
        timestamp: ProcessInfo.processInfo.systemUptime
    )

    MainActor.assumeIsolated { monitor.handle(snapshot: snapshot) }
    // .listenOnly — always pass the event through untouched.
    return Unmanaged.passUnretained(event)
}

/// How long a hands-free session may run before it ends itself.
///
/// Under the capture buffer's 300 s ceiling (AVAudioEngineCapture), so a
/// hands-free session ends and is transcribed before audio could overflow and
/// clip the tail of what was said. The HUD counts down the last
/// `warningWindow` seconds, so a long dictation is never cut off unannounced.
enum HandsFreeLimit {
    static let ceiling: Double = 285
    static let warningWindow: Double = 15

    /// `--hands-free-limit <seconds>` shortens it, so the countdown can be
    /// checked live in half a minute. Clamped: it can never exceed the ceiling.
    static let seconds: Double = {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--hands-free-limit"),
              index + 1 < arguments.count,
              let value = Double(arguments[index + 1])
        else { return ceiling }
        return min(max(value, 10), ceiling)
    }()
}
