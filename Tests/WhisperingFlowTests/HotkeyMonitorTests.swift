import CoreGraphics
import Foundation
import HotkeyGestureCore
import Testing
@testable import WhisperingFlowKit

// MARK: - Flag translation

@Suite("Modifier flag translation")
struct ModifierFlagMappingTests {

    // NX_DEVICE*KEYMASK, the device-dependent bits. If these are ever wrong the
    // app binds the wrong physical key and the bug is invisible in a log — the
    // Phase 2 spike shipped with Left and Right Command transposed.
    private static let nxLeftControl:  UInt64 = 0x00000001
    private static let nxLeftShift:    UInt64 = 0x00000002
    private static let nxRightShift:   UInt64 = 0x00000004
    private static let nxLeftCommand:  UInt64 = 0x00000008
    private static let nxRightCommand: UInt64 = 0x00000010
    private static let nxLeftOption:   UInt64 = 0x00000020
    private static let nxRightOption:  UInt64 = 0x00000040
    private static let nxRightControl: UInt64 = 0x00002000

    @Test("Right Command is not confused with Left Command")
    func commandSidesAreDistinct() {
        let right = ModifierFlagMapping.modifiers(
            from: UInt64(CGEventFlags.maskCommand.rawValue) | Self.nxRightCommand)
        let left = ModifierFlagMapping.modifiers(
            from: UInt64(CGEventFlags.maskCommand.rawValue) | Self.nxLeftCommand)

        #expect(right.contains(.rightCommand))
        #expect(!right.contains(.leftCommand))
        #expect(left.contains(.leftCommand))
        #expect(!left.contains(.rightCommand))
    }

    @Test("Every side-discriminated modifier maps to its own bit")
    func everySideMapsIndependently() {
        let cases: [(UInt64, Modifiers)] = [
            (Self.nxLeftControl, .leftControl),
            (Self.nxRightControl, .rightControl),
            (Self.nxLeftShift, .leftShift),
            (Self.nxRightShift, .rightShift),
            (Self.nxLeftCommand, .leftCommand),
            (Self.nxRightCommand, .rightCommand),
            (Self.nxLeftOption, .leftOption),
            (Self.nxRightOption, .rightOption),
        ]
        for (raw, expected) in cases {
            let mapped = ModifierFlagMapping.modifiers(from: raw)
            #expect(mapped == expected, "0x\(String(raw, radix: 16)) mapped to \(mapped.displayNames)")
        }
    }

    @Test("A bare ⌘ mask with no device bit matches neither side")
    func genericCommandMatchesNoSide() {
        // Synthetic events (and some remapping utilities) set only the generic
        // mask. Binding Right Command must not fire for those.
        let mapped = ModifierFlagMapping.modifiers(from: UInt64(CGEventFlags.maskCommand.rawValue))
        #expect(!mapped.contains(.rightCommand))
        #expect(!mapped.contains(.leftCommand))
    }

    @Test("Fn and Caps Lock come from the generic flags")
    func genericOnlyModifiers() {
        let fn = ModifierFlagMapping.modifiers(from: UInt64(CGEventFlags.maskSecondaryFn.rawValue))
        let caps = ModifierFlagMapping.modifiers(from: UInt64(CGEventFlags.maskAlphaShift.rawValue))
        #expect(fn == .function)
        #expect(caps == .capsLock)
    }
}

// MARK: - Diagnostics

@Suite("Event-tap health")
struct HotkeyDiagnosticsTests {

    @Test("A tap that was never installed reads as notStarted")
    func notStarted() {
        #expect(HotkeyDiagnostics().health == .notStarted)
    }

    @Test("An installed tap that has never seen an event reads as installedButSilent")
    func silentTap() {
        var d = HotkeyDiagnostics()
        d.isTapInstalled = true
        // This is the stale-Input-Monitoring signature: creation succeeds, then
        // nothing ever arrives. Indistinguishable from "user pressed nothing"
        // unless the two signals are kept apart.
        #expect(d.health == .installedButSilent)
        #expect(d.summary.contains("Input Monitoring"))
    }

    @Test("Events flowing with no match reads as receivingButUnmatched, not as a dead tap")
    func unmatchedBinding() {
        var d = HotkeyDiagnostics()
        d.isTapInstalled = true
        d.hasReceivedAnyEvent = true
        d.eventCount = 412
        #expect(d.health == .receivingButUnmatched)
        #expect(d.summary.contains("412"))
    }

    @Test("A matched trigger reads as working")
    func working() {
        var d = HotkeyDiagnostics()
        d.isTapInstalled = true
        d.hasReceivedAnyEvent = true
        d.eventCount = 12
        d.matchedTriggerCount = 3
        #expect(d.health == .working)
    }
}

// MARK: - Monitor

@Suite("CGEventTap hotkey monitor")
@MainActor
struct CGEventTapHotkeyMonitorTests {

    private func makeMonitor(
        binding: HotkeyBinding = .bareModifier(.rightCommand),
        mode: TriggerMode = .hold
    ) -> CGEventTapHotkeyMonitor {
        CGEventTapHotkeyMonitor(binding: binding, triggerMode: mode, holdThreshold: 0.15)
    }

    private func flags(_ modifiers: Modifiers, at t: Double) -> HotkeyEvent {
        HotkeyEvent(kind: .flagsChanged, keyCode: 54, modifiers: modifiers, timestamp: t)
    }

    private func escape(at t: Double) -> HotkeyEvent {
        HotkeyEvent(kind: .keyDown, keyCode: PressGesture.escapeKeyCode, modifiers: [], timestamp: t)
    }

    @Test("A held trigger begins only after the hold timer fires")
    func holdBegins() {
        let monitor = makeMonitor()
        var began = 0, ended = 0
        monitor.onPress = { began += 1 }
        monitor.onRelease = { ended += 1 }

        monitor.injectForTesting(flags(.rightCommand, at: 100))
        #expect(began == 0, "begin must wait for the threshold, never fire on the physical press")

        monitor.fireHoldTimerForTesting()
        #expect(began == 1)

        monitor.injectForTesting(flags([], at: 100.9))
        #expect(ended == 1)
        #expect(monitor.diagnostics.sessionsBegun == 1)
        #expect(monitor.diagnostics.sessionsEnded == 1)
    }

    private func handsFreeMonitor() -> CGEventTapHotkeyMonitor {
        CGEventTapHotkeyMonitor(binding: .bareModifier(.rightCommand), triggerMode: .hold,
                                holdThreshold: 0.15, handsFree: true)
    }

    @Test("Double-tap opens one hands-free session; the next tap ends it")
    func doubleTapThroughTheMonitor() {
        let monitor = handsFreeMonitor()
        var began = 0, ended = 0, locked = 0, cancelled = 0
        monitor.onPress = { began += 1 }
        monitor.onRelease = { ended += 1 }
        monitor.onCancel = { cancelled += 1 }
        monitor.onHandsFreeLocked = { locked += 1 }

        monitor.injectForTesting(flags(.rightCommand, at: 100))
        monitor.injectForTesting(flags([], at: 100.06))
        #expect(began == 0)
        monitor.injectForTesting(flags(.rightCommand, at: 100.20))
        #expect(began == 1 && locked == 1)
        monitor.injectForTesting(flags([], at: 100.27))
        #expect(ended == 0, "releasing the locking press must not end a hands-free session")

        // Ten seconds of speech later, one tap finishes it.
        monitor.injectForTesting(flags(.rightCommand, at: 110))
        #expect(ended == 1)
        monitor.injectForTesting(flags([], at: 110.05))
        #expect(ended == 1, "the stop press's own release is swallowed")
        #expect(cancelled == 1, "only the first tap's discarded pre-roll cancelled")
        #expect(monitor.diagnostics.sessionsBegun == 1)
        #expect(monitor.diagnostics.sessionsEnded == 1)
    }

    @Test("The hands-free safety limit ends the session instead of leaving the mic open")
    func handsFreeLimitEnds() {
        let monitor = handsFreeMonitor()
        var ended = 0
        monitor.onRelease = { ended += 1 }
        monitor.injectForTesting(flags(.rightCommand, at: 100))
        monitor.injectForTesting(flags([], at: 100.06))
        monitor.injectForTesting(flags(.rightCommand, at: 100.20))
        monitor.injectForTesting(flags([], at: 100.27))

        monitor.fireHandsFreeLimitForTesting()
        #expect(ended == 1)
        // Fired twice by accident: still one end.
        monitor.fireHandsFreeLimitForTesting()
        #expect(ended == 1)
    }

    @Test("With hands-free off, two quick taps never start anything")
    func handsFreeOffDoesNothing() {
        let monitor = makeMonitor()
        var began = 0
        monitor.onPress = { began += 1 }
        monitor.injectForTesting(flags(.rightCommand, at: 100))
        monitor.injectForTesting(flags([], at: 100.06))
        monitor.injectForTesting(flags(.rightCommand, at: 100.20))
        monitor.injectForTesting(flags([], at: 100.26))
        #expect(began == 0)
    }

    @Test("A tap shorter than the threshold produces no session at all")
    func accidentalTapIsSwallowed() {
        let monitor = makeMonitor()
        var began = 0, ended = 0
        monitor.onPress = { began += 1 }
        monitor.onRelease = { ended += 1 }

        monitor.injectForTesting(flags(.rightCommand, at: 100))
        monitor.injectForTesting(flags([], at: 100.05))
        // A late timer must not resurrect the gesture.
        monitor.fireHoldTimerForTesting()

        #expect(began == 0)
        #expect(ended == 0, "an end without a begin would leave the coordinator transcribing nothing")
    }

    @Test("⌘C does not start dictation")
    func ordinaryCommandShortcutIsIgnored() {
        let monitor = makeMonitor()
        var began = 0
        monitor.onPress = { began += 1 }

        // Left Command down, then the C keystroke, then release. This is the
        // regression that matters most: the binding is a live system modifier.
        monitor.injectForTesting(flags(.leftCommand, at: 200))
        monitor.injectForTesting(HotkeyEvent(kind: .keyDown, keyCode: 8,
                                             modifiers: .leftCommand, timestamp: 200.02))
        monitor.injectForTesting(HotkeyEvent(kind: .keyUp, keyCode: 8,
                                             modifiers: .leftCommand, timestamp: 200.08))
        monitor.injectForTesting(flags([], at: 200.1))
        monitor.fireHoldTimerForTesting()

        #expect(began == 0)
        #expect(monitor.diagnostics.matchedTriggerCount == 0)
        #expect(monitor.diagnostics.eventCount == 4, "events are still observed, just not matched")
    }

    @Test("Escape during an active session cancels it, and the later release is swallowed")
    func escapeCancels() {
        let monitor = makeMonitor()
        var began = 0, ended = 0, cancelled = 0
        monitor.onPress = { began += 1 }
        monitor.onRelease = { ended += 1 }
        monitor.onCancel = { cancelled += 1 }

        monitor.injectForTesting(flags(.rightCommand, at: 300))
        monitor.fireHoldTimerForTesting()
        #expect(began == 1)

        monitor.injectForTesting(escape(at: 300.5))
        #expect(cancelled == 1)

        monitor.injectForTesting(flags([], at: 300.9))
        #expect(ended == 0, "a cancelled session must not also be ended — that would insert the text")
        #expect(monitor.diagnostics.sessionsCancelled == 1)
    }

    @Test("Escape with no session running does nothing")
    func escapeIsInertWhenIdle() {
        let monitor = makeMonitor()
        var cancelled = 0
        monitor.onCancel = { cancelled += 1 }
        monitor.injectForTesting(escape(at: 400))
        #expect(cancelled == 0)
    }

    @Test("Auto-repeat while held does not begin a second session")
    func autoRepeatIsIgnored() {
        let monitor = makeMonitor(binding: .key(keyCode: 97, required: []))
        var began = 0
        monitor.onPress = { began += 1 }

        monitor.injectForTesting(HotkeyEvent(kind: .keyDown, keyCode: 97,
                                             modifiers: [], timestamp: 500))
        monitor.fireHoldTimerForTesting()
        for i in 1...20 {
            monitor.injectForTesting(HotkeyEvent(kind: .keyDown, keyCode: 97, modifiers: [],
                                                 isAutoRepeat: true, timestamp: 500 + Double(i) * 0.03))
        }
        #expect(began == 1)
    }

    @Test("Re-enabling a disabled tap never creates a second tap")
    func recoveryDoesNotDuplicateTheTap() {
        let monitor = makeMonitor()
        let createdBefore = monitor.diagnostics.tapCreatedCount

        monitor.handleTapDisabled(reason: "timeout")
        monitor.handleTapDisabled(reason: "user input")
        monitor.handleTapDisabled(reason: "timeout")

        #expect(monitor.diagnostics.tapDisabledCount == 3)
        #expect(monitor.diagnostics.tapCreatedCount == createdBefore,
                "recovery must re-enable the existing port; a second tapCreate means duplicate events")
    }

    @Test("A tap disabled mid-gesture drops the half-finished press")
    func recoveryResetsTheGesture() {
        let monitor = makeMonitor()
        var began = 0
        monitor.onPress = { began += 1 }

        monitor.injectForTesting(flags(.rightCommand, at: 600))
        #expect(monitor.gesture.isAwaitingThreshold)

        // macOS disabled the tap while the key was still down. The key-up will
        // never be delivered, so keeping the pending press would strand it.
        monitor.handleTapDisabled(reason: "timeout")
        #expect(!monitor.gesture.isAwaitingThreshold)

        monitor.fireHoldTimerForTesting()
        #expect(began == 0)
    }

    @Test("Rebinding drops any gesture in flight")
    func rebindResetsTheGesture() {
        let monitor = makeMonitor()
        var began = 0
        monitor.onPress = { began += 1 }

        monitor.injectForTesting(flags(.rightCommand, at: 700))
        monitor.update(binding: .bareModifier(.leftControl), triggerMode: .hold, handsFree: false)
        monitor.fireHoldTimerForTesting()

        #expect(began == 0)
        #expect(monitor.gesture.binding == .bareModifier(.leftControl))
    }

    @Test("Rebinding during a live session cancels it instead of stranding the microphone")
    func rebindDuringASessionCancelsIt() {
        // Threshold 0 so the injected clock can stay still: this test is about
        // what `update` does to a session, not about the threshold itself.
        let monitor = CGEventTapHotkeyMonitor(binding: .bareModifier(.rightCommand),
                                              triggerMode: .hold, holdThreshold: 0,
                                              now: { 700 })
        var began = 0, cancelled = 0
        monitor.onPress = { began += 1 }
        monitor.onCancel = { cancelled += 1 }

        monitor.injectForTesting(flags(.rightCommand, at: 700))
        monitor.fireHoldTimerForTesting()
        #expect(began == 1)

        monitor.update(binding: .bareModifier(.leftControl), triggerMode: .hold, handsFree: false)

        // Without this the coordinator stayed in `.listening` with the
        // microphone open and no gesture left that could end it.
        #expect(cancelled == 1, "the open session must be cancelled, not abandoned")
        #expect(!monitor.gesture.hasActiveSession)
    }

    @Test("Rebinding during a hands-free session cancels it and disarms the safety limit")
    func rebindDuringHandsFreeCancelsIt() {
        let monitor = CGEventTapHotkeyMonitor(binding: .bareModifier(.rightCommand),
                                              triggerMode: .hold, holdThreshold: 0.15,
                                              handsFree: true,
                                              now: { 1000 })
        var began = 0, ended = 0, cancelled = 0
        monitor.onPress = { began += 1 }
        monitor.onRelease = { ended += 1 }
        monitor.onCancel = { cancelled += 1 }

        monitor.injectForTesting(flags(.rightCommand, at: 1000))      // tap one down
        monitor.injectForTesting(flags([], at: 1000.05))              // tap one up (discards pre-roll)
        monitor.injectForTesting(flags(.rightCommand, at: 1000.2))    // tap two locks it open
        monitor.injectForTesting(flags([], at: 1000.25))
        #expect(began == 1)
        #expect(monitor.gesture.isHandsFree)
        let cancelsBefore = cancelled

        monitor.update(binding: .bareModifier(.rightCommand), triggerMode: .hold, handsFree: false)

        #expect(cancelled == cancelsBefore + 1, "the locked-open session must be cancelled")
        #expect(!monitor.gesture.hasActiveSession)
        // The limit timer is gone too, so it cannot resurrect the session later.
        monitor.fireHandsFreeLimitForTesting()
        #expect(ended == 0)
    }

    @Test("Starting is idempotent, and a failure to start is reported as notStarted")
    func startIsIdempotent() throws {
        let monitor = makeMonitor()
        do {
            try monitor.start()
            // Input Monitoring is available to this process.
            #expect(monitor.diagnostics.tapCreatedCount == 1)
            try monitor.start()
            #expect(monitor.diagnostics.tapCreatedCount == 1, "a second start must not install a second tap")
            monitor.stop()
            #expect(monitor.diagnostics.health == .notStarted)
        } catch {
            // Test processes usually inherit the terminal's TCC grants, which
            // normally lack Input Monitoring. The failure path is the one that
            // matters then: it must be visible, not silent.
            #expect(error is HotkeyMonitorError)
            #expect(monitor.diagnostics.isTapInstalled == false)
            #expect(monitor.diagnostics.tapCreatedCount == 0)
            #expect(monitor.diagnostics.health == .notStarted)
        }
    }

    /// Mutable monotonic clock for the latency assertions.
    @MainActor private final class TestClock: @unchecked Sendable {
        var value: Double = 1_000
    }

    @Test("press→begin is measured from the physical press, not the timer deadline")
    func beginLatencyIsMeasuredFromThePress() {
        let clock = TestClock()
        let monitor = CGEventTapHotkeyMonitor(binding: .bareModifier(.rightCommand),
                                              triggerMode: .hold,
                                              holdThreshold: 0.15,
                                              now: { clock.value })

        clock.value = 1_000
        monitor.injectForTesting(flags(.rightCommand, at: 1_000))
        // Timers overshoot; the sample must reflect what the user felt.
        clock.value = 1_000.162
        monitor.fireHoldTimerForTesting()

        #expect(monitor.pressToBeginSamples.count == 1)
        #expect(abs((monitor.pressToBeginSamples.first ?? 0) - 162) < 0.5)

        clock.value = 1_002.004
        monitor.injectForTesting(flags([], at: 1_002.0))
        #expect(abs((monitor.releaseToEndSamples.first ?? 0) - 4) < 0.5)
        #expect(monitor.latencySummary.contains("threshold=150ms"))
    }

    @Test("Percentiles are withheld until the sample size supports them")
    func percentileGuardsSmallSamples() {
        // A "p95" over ten samples is just the maximum wearing a label.
        #expect(CGEventTapHotkeyMonitor.percentile([5], 0.50) == nil)
        #expect(CGEventTapHotkeyMonitor.percentile([5, 7], 0.50) == 5)
        let ten = (1...10).map(Double.init)
        #expect(CGEventTapHotkeyMonitor.percentile(ten, 0.50) == 5)
        #expect(CGEventTapHotkeyMonitor.percentile(ten, 0.95) == nil)
        let twenty = (1...20).map(Double.init)
        #expect(CGEventTapHotkeyMonitor.percentile(twenty, 0.95) == 19)
    }
}

// MARK: - Offered bindings

@Suite("Offered hotkey bindings")
struct HotkeyBindingCatalogueTests {

    @Test("Only keys that exist on the target keyboard are offered")
    func cataloguesMatchTheHardware() {
        // This keyboard has one Control (left), both Options, both Commands and
        // F1–F12. Offering F13 or Right Control means offering a key the user
        // physically cannot press.
        let names = HotkeyBinding.selectable.map(\.displayName)
        #expect(!names.contains("Right Control"))
        #expect(!names.contains { $0.hasPrefix("F1") && $0 != "F1" })
        for binding in HotkeyBinding.selectable {
            guard case .key = binding else { continue }
            #expect(["F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12"].contains(binding.displayName),
                    "\(binding.displayName) is not on this keyboard")
        }
    }

    @Test("Right Command is the default and is offered")
    func defaultIsOffered() {
        #expect(Preferences.default.hotkey == .bareModifier(.rightCommand))
        #expect(HotkeyBinding.selectable.contains(.bareModifier(.rightCommand)))
    }
}

// MARK: - Stored-preference migration

@Suite("Stored hotkey migration")
@MainActor
struct HotkeyMigrationTests {

    @Test("A stored binding for a key that no longer exists falls back to the default")
    func retiredBindingIsMigrated() {
        var stored = Preferences.default
        stored.hotkey = .key(keyCode: 105, required: [])   // F13, offered in Phase 3
        #expect(SettingsStore.migrate(stored).hotkey == Preferences.default.hotkey)

        stored.hotkey = .bareModifier(.rightControl)        // not on this keyboard
        #expect(SettingsStore.migrate(stored).hotkey == Preferences.default.hotkey)
    }

    @Test("A still-offered binding is left alone")
    func validBindingSurvives() {
        var stored = Preferences.default
        stored.hotkey = .bareModifier(.leftControl)
        #expect(SettingsStore.migrate(stored).hotkey == .bareModifier(.leftControl))
    }

    @Test("The hands-free preference persists and defaults on for existing users")
    func handsFreePersists() {
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        let first = SettingsStore(defaults: defaults)
        #expect(first.preferences.handsFreeDoubleTap, "an existing install has no stored value and must get the feature")
        first.preferences.handsFreeDoubleTap = false
        #expect(SettingsStore(defaults: defaults).preferences.handsFreeDoubleTap == false)
    }

    @Test("Migration preserves every other preference")
    func migrationTouchesOnlyTheHotkey() {
        var stored = Preferences.default
        stored.hotkey = .key(keyCode: 105, required: [])
        stored.locale = .spanishES
        stored.processingMode = .smart
        stored.triggerMode = .toggle

        let migrated = SettingsStore.migrate(stored)
        #expect(migrated.locale == .spanishES)
        #expect(migrated.processingMode == .smart)
        #expect(migrated.triggerMode == .toggle)
    }
}

@Suite("Hold threshold survives slow pre-roll handlers")
@MainActor
struct HoldThresholdDriftTests {

    @MainActor private final class Clock: @unchecked Sendable { var value: Double = 500 }

    @Test("Time spent starting audio capture does not delay begin")
    func captureStartDoesNotPushOutTheThreshold() {
        // `onTriggerPressed` starts AVAudioEngine synchronously, which measured
        // ~53 ms in Phase 5. If the hold timer is armed for its full interval
        // *after* that, begin lands at ~203 ms instead of 150 — quietly
        // changing the threshold ADR-016 locked on measured evidence.
        let clock = Clock()
        let monitor = CGEventTapHotkeyMonitor(binding: .bareModifier(.rightCommand),
                                              triggerMode: .hold,
                                              holdThreshold: 0.15,
                                              now: { clock.value })
        var armedFor: Double?
        monitor.onTriggerPressed = { clock.value += 0.053 }      // audio engine start
        monitor.onHoldTimerArmedForTesting = { armedFor = $0 }

        clock.value = 500
        monitor.injectForTesting(HotkeyEvent(kind: .flagsChanged, keyCode: 54,
                                             modifiers: .rightCommand, timestamp: 500))

        let interval = armedFor ?? -1
        #expect(abs(interval - 0.097) < 0.001,
                "expected the remaining 97 ms, got \(interval * 1000) ms — begin would land at \((0.053 + interval) * 1000) ms instead of 150")
    }

    @Test("A handler slower than the whole threshold begins immediately, not late")
    func verySlowHandlerDoesNotGoNegative() {
        let clock = Clock()
        let monitor = CGEventTapHotkeyMonitor(binding: .bareModifier(.rightCommand),
                                              triggerMode: .hold,
                                              holdThreshold: 0.15,
                                              now: { clock.value })
        var armedFor: Double?
        monitor.onTriggerPressed = { clock.value += 0.4 }
        monitor.onHoldTimerArmedForTesting = { armedFor = $0 }

        clock.value = 500
        monitor.injectForTesting(HotkeyEvent(kind: .flagsChanged, keyCode: 54,
                                             modifiers: .rightCommand, timestamp: 500))
        #expect(armedFor == 0, "a negative interval must clamp, not schedule in the past")
    }
}
