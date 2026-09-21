import Testing
@testable import HotkeyGestureCore

private let rightCommand = HotkeyBinding.bareModifier(.rightCommand)
private let threshold = 0.15

private func flags(_ mods: Modifiers, at t: Double) -> HotkeyEvent {
    HotkeyEvent(kind: .flagsChanged, keyCode: 0, modifiers: mods, timestamp: t)
}

private func escape(at t: Double, autoRepeat: Bool = false) -> HotkeyEvent {
    HotkeyEvent(kind: .keyDown, keyCode: PressGesture.escapeKeyCode,
                modifiers: [], isAutoRepeat: autoRepeat, timestamp: t)
}

private func makeGesture(mode: TriggerMode = .hold) -> PressGesture {
    PressGesture(binding: rightCommand, mode: mode, holdThreshold: threshold)
}

/// Press, wait past the threshold, and collect what the machine emitted.
private func pressAndHold(_ g: inout PressGesture, pressAt: Double = 0) -> [PressGesture.Intent] {
    var out = g.handle(flags(.rightCommand, at: pressAt))
    out += g.holdThresholdElapsed(at: pressAt + threshold)
    return out
}

@Suite("PressGesture — hold threshold (AC 5, 6)")
struct HoldThresholdTests {

    @Test("A hold past the threshold produces exactly one begin")
    func holdBegins() {
        var g = makeGesture()
        let armed = g.handle(flags(.rightCommand, at: 0))
        // triggerPressed comes first and unconditionally: audio pre-roll must
        // start on the physical press, not 151 ms later (ADR-018).
        #expect(armed == [.triggerPressed, .armHoldTimer(deadline: threshold)])
        #expect(g.isAwaitingThreshold)

        let began = g.holdThresholdElapsed(at: threshold)
        #expect(began == [.begin])
        #expect(g.hasActiveSession)
    }

    @Test("No begin is emitted before the threshold elapses")
    func noBeginBeforeThreshold() {
        var g = makeGesture()
        _ = g.handle(flags(.rightCommand, at: 0))
        #expect(g.holdThresholdElapsed(at: 0.10).isEmpty)
        #expect(!g.hasActiveSession)
    }

    @Test("An accidental tap produces NO begin and NO end, and discards its capture")
    func accidentalTapIsSilent() {
        var g = makeGesture()
        let pressed = g.handle(flags(.rightCommand, at: 0))
        #expect(pressed.contains(.triggerPressed))

        let released = g.handle(flags([], at: 0.05))
        #expect(!released.contains(.begin))
        #expect(!released.contains(.end))
        // The pre-roll started at triggerPressed, so it has to be thrown away —
        // otherwise every stray ⌘ press leaves recorded audio in memory.
        #expect(released == [.cancelHoldTimer, .cancel])
        #expect(!g.hasActiveSession)
        // A timer that fires late must not resurrect the session.
        #expect(g.holdThresholdElapsed(at: threshold).isEmpty)
    }

    @Test("Five rapid taps in a row produce no sessions at all", arguments: [0.01, 0.05, 0.1, 0.149])
    func rapidTapsNeverStart(holdFor: Double) {
        var g = makeGesture()
        var emitted: [PressGesture.Intent] = []
        for index in 0..<5 {
            let base = Double(index) * 0.2
            emitted += g.handle(flags(.rightCommand, at: base))
            emitted += g.handle(flags([], at: base + holdFor))
            emitted += g.holdThresholdElapsed(at: base + threshold)
        }
        #expect(!emitted.contains(.begin))
        #expect(!emitted.contains(.end))
    }

    @Test("A hold exactly at the threshold begins")
    func exactlyAtThresholdBegins() {
        var g = makeGesture()
        _ = g.handle(flags(.rightCommand, at: 0))
        #expect(g.holdThresholdElapsed(at: threshold) == [.begin])
    }
}

@Suite("PressGesture — release and cancel (AC 7, 8, 9)")
struct ReleaseAndCancelTests {

    @Test("Releasing an active hold produces exactly one end")
    func releaseEnds() {
        var g = makeGesture()
        _ = pressAndHold(&g)
        #expect(g.handle(flags([], at: 2.0)) == [.end])
        #expect(!g.hasActiveSession)
    }

    @Test("Escape during an active hold produces exactly one cancel")
    func escapeCancels() {
        var g = makeGesture()
        _ = pressAndHold(&g)
        #expect(g.handle(escape(at: 0.5)) == [.cancel])
        #expect(!g.hasActiveSession)
    }

    @Test("Releasing AFTER a cancel does not produce a spurious end")
    func releaseAfterCancelIsSilent() {
        var g = makeGesture()
        _ = pressAndHold(&g)
        #expect(g.handle(escape(at: 0.5)) == [.cancel])
        #expect(g.handle(flags([], at: 1.0)).isEmpty)
    }

    @Test("Escape before the threshold disarms and discards the pre-roll")
    func escapeBeforeThreshold() {
        var g = makeGesture()
        _ = g.handle(flags(.rightCommand, at: 0))
        let out = g.handle(escape(at: 0.05))
        // No session had begun, so no `begin`/`end` — but provisional capture
        // is running and must be dropped.
        #expect(out == [.cancelHoldTimer, .cancel])
        #expect(!out.contains(.begin))
        #expect(g.holdThresholdElapsed(at: threshold).isEmpty)
    }

    @Test("Escape with no session is ignored")
    func escapeIdleIgnored() {
        var g = makeGesture()
        #expect(g.handle(escape(at: 0)).isEmpty)
    }

    @Test("A release with no matching press is ignored")
    func strayReleaseIgnored() {
        var g = makeGesture()
        #expect(g.handle(flags([], at: 0)).isEmpty)
    }
}

@Suite("PressGesture — duplicate and corruption guards (AC 10, 11)")
struct DuplicateGuardTests {

    @Test("Auto-repeat cannot create a second session")
    func autoRepeatIgnored() {
        var g = makeGesture()
        var out = pressAndHold(&g)
        let repeated = HotkeyEvent(kind: .flagsChanged, keyCode: 0,
                                   modifiers: .rightCommand, isAutoRepeat: true, timestamp: 0.5)
        for _ in 0..<10 { out += g.handle(repeated) }
        #expect(out.filter { $0 == .begin }.count == 1)
    }

    @Test("Repeated flagsChanged with the trigger still down cannot re-begin")
    func repeatedDownIsIdempotent() {
        var g = makeGesture()
        var out = pressAndHold(&g)
        // Another modifier joining produces further flagsChanged events that
        // still satisfy the binding. None may start a second session.
        for t in [0.3, 0.4, 0.5] {
            out += g.handle(flags([.rightCommand, .leftShift], at: t))
        }
        #expect(out.filter { $0 == .begin }.count == 1)
        #expect(g.hasActiveSession)
    }

    @Test("Releasing twice produces only one end")
    func doubleReleaseIsOneEnd() {
        var g = makeGesture()
        _ = pressAndHold(&g)
        var out = g.handle(flags([], at: 1.0))
        out += g.handle(flags([], at: 1.1))
        #expect(out.filter { $0 == .end }.count == 1)
    }

    @Test("Twenty rapid press/release cycles keep begins and ends balanced")
    func rapidCyclesStayBalanced() {
        var g = makeGesture()
        var begins = 0, ends = 0
        for index in 0..<20 {
            let base = Double(index)
            for intent in pressAndHold(&g, pressAt: base) where intent == .begin { begins += 1 }
            for intent in g.handle(flags([], at: base + 0.5)) where intent == .end { ends += 1 }
        }
        #expect(begins == 20)
        #expect(ends == 20)
        #expect(!g.hasActiveSession)
    }

    @Test("A cancel mid-run does not desynchronise later cycles")
    func cancelDoesNotDesync() {
        var g = makeGesture()
        _ = pressAndHold(&g)
        _ = g.handle(escape(at: 0.3))
        _ = g.handle(flags([], at: 0.4))
        // Next cycle must behave normally.
        #expect(pressAndHold(&g, pressAt: 1.0).contains(.begin))
        #expect(g.handle(flags([], at: 1.5)) == [.end])
    }

    @Test("Reset clears a half-finished gesture")
    func resetClears() {
        var g = makeGesture()
        _ = pressAndHold(&g)
        #expect(g.hasActiveSession)
        g.reset()
        #expect(!g.hasActiveSession)
        #expect(g.handle(flags([], at: 1.0)).isEmpty)
    }
}

@Suite("PressGesture — binding isolation (AC 4, 12, 13, 14)")
struct BindingIsolationTests {

    @Test("Left Command never triggers a Right Command binding")
    func leftCommandIgnored() {
        var g = makeGesture()
        var out = g.handle(flags(.leftCommand, at: 0))
        out += g.holdThresholdElapsed(at: threshold)
        out += g.handle(flags([], at: 0.5))
        #expect(out.isEmpty)
    }

    @Test("Right Option never triggers a Right Command binding")
    func rightOptionIgnored() {
        var g = makeGesture()
        var out = g.handle(flags(.rightOption, at: 0))
        out += g.holdThresholdElapsed(at: threshold)
        #expect(out.isEmpty)
    }

    @Test("Ordinary typing produces nothing")
    func typingIgnored() {
        var g = makeGesture()
        var out: [PressGesture.Intent] = []
        for code in UInt16(0)..<UInt16(50) where code != PressGesture.escapeKeyCode {
            out += g.handle(HotkeyEvent(kind: .keyDown, keyCode: code, modifiers: [], timestamp: 0))
            out += g.handle(HotkeyEvent(kind: .keyUp, keyCode: code, modifiers: [], timestamp: 0.01))
        }
        #expect(out.isEmpty)
    }

    @Test("Command shortcuts with Left Command are untouched")
    func leftCommandShortcutsUntouched() {
        var g = makeGesture()
        // ⌘C: left command down, C down, C up, left command up.
        var out = g.handle(flags(.leftCommand, at: 0))
        out += g.handle(HotkeyEvent(kind: .keyDown, keyCode: 8, modifiers: .leftCommand, timestamp: 0.01))
        out += g.handle(HotkeyEvent(kind: .keyUp, keyCode: 8, modifiers: .leftCommand, timestamp: 0.02))
        out += g.handle(flags([], at: 0.03))
        #expect(out.isEmpty)
    }

    @Test("A quick Right Command shortcut does not start dictation")
    func rightCommandShortcutIsSafe() {
        // ⌘C typed with the RIGHT command key, completed inside the threshold.
        var g = makeGesture()
        var out = g.handle(flags(.rightCommand, at: 0))
        out += g.handle(HotkeyEvent(kind: .keyDown, keyCode: 8, modifiers: .rightCommand, timestamp: 0.02))
        out += g.handle(HotkeyEvent(kind: .keyUp, keyCode: 8, modifiers: .rightCommand, timestamp: 0.04))
        out += g.handle(flags([], at: 0.06))
        out += g.holdThresholdElapsed(at: threshold)
        #expect(!out.contains(.begin))
        #expect(!out.contains(.end))
    }
}

@Suite("PressGesture — toggle mode")
struct ToggleModeTests {

    @Test("Toggle still requires a deliberate hold to start")
    func toggleRequiresHoldToStart() {
        var g = makeGesture(mode: .toggle)
        _ = g.handle(flags(.rightCommand, at: 0))
        _ = g.handle(flags([], at: 0.05))
        #expect(g.holdThresholdElapsed(at: threshold).isEmpty)
        #expect(!g.hasActiveSession)
    }

    @Test("Releasing does not stop a toggle session; the next press does")
    func toggleStopsOnNextPress() {
        var g = makeGesture(mode: .toggle)
        #expect(pressAndHold(&g).contains(.begin))
        #expect(g.handle(flags([], at: 0.5)).isEmpty)
        #expect(g.hasActiveSession)
        #expect(g.handle(flags(.rightCommand, at: 1.0)) == [.end])
        #expect(!g.hasActiveSession)
    }

    @Test("Escape cancels a toggle session")
    func toggleEscapeCancels() {
        var g = makeGesture(mode: .toggle)
        _ = pressAndHold(&g)
        _ = g.handle(flags([], at: 0.5))
        #expect(g.handle(escape(at: 1.0)) == [.cancel])
    }
}

@Suite("HotkeyBinding")
struct HotkeyBindingTests {

    @Test("Bare modifier binding discriminates left from right")
    func leftRightDiscrimination() {
        let binding = HotkeyBinding.bareModifier(.rightCommand)
        #expect(binding.isSatisfied(by: flags(.rightCommand, at: 0)))
        #expect(!binding.isSatisfied(by: flags(.leftCommand, at: 0)))
    }

    @Test("Key binding requires its modifiers")
    func keyBindingRequiresModifiers() {
        let binding = HotkeyBinding.key(keyCode: 49, required: [.leftControl])
        #expect(binding.isSatisfied(by: HotkeyEvent(kind: .keyDown, keyCode: 49,
                                                    modifiers: [.leftControl], timestamp: 0)))
        #expect(!binding.isSatisfied(by: HotkeyEvent(kind: .keyDown, keyCode: 49,
                                                     modifiers: [], timestamp: 0)))
    }
}

@Suite("triggerPressed — pre-roll signal (ADR-018)")
struct TriggerPressedTests {

    @Test("triggerPressed precedes the hold timer, so capture starts first")
    func orderingPutsCaptureFirst() {
        var g = makeGesture()
        let out = g.handle(flags(.rightCommand, at: 0))
        #expect(out.first == .triggerPressed,
                "arming the timer before starting capture would waste the head of the buffer")
    }

    @Test("Every triggerPressed is eventually resolved by begin or cancel")
    func neverStrandsCapture() {
        // Capture started at triggerPressed is only released by `begin`
        // (promoted) or `cancel` (discarded). A path that emits neither leaks a
        // running microphone.
        var tap = makeGesture()
        _ = tap.handle(flags(.rightCommand, at: 0))
        #expect(tap.handle(flags([], at: 0.05)).contains(.cancel))

        var held = makeGesture()
        _ = held.handle(flags(.rightCommand, at: 0))
        #expect(held.holdThresholdElapsed(at: threshold).contains(.begin))

        var escaped = makeGesture()
        _ = escaped.handle(flags(.rightCommand, at: 0))
        #expect(escaped.handle(escape(at: 0.05)).contains(.cancel))
    }

    @Test("A second flagsChanged while already held does not restart capture")
    func noDuplicateTriggerPressed() {
        var g = makeGesture()
        _ = g.handle(flags(.rightCommand, at: 0))
        // A modifier added alongside the trigger re-fires flagsChanged with the
        // trigger still set. Restarting the pre-roll here would discard the
        // audio captured so far.
        let again = g.handle(flags([.rightCommand, .leftShift], at: 0.05))
        #expect(!again.contains(.triggerPressed))
        #expect(again.isEmpty)
    }

    @Test("Toggle mode also pre-rolls from the physical press")
    func toggleAlsoPreRolls() {
        var g = PressGesture(binding: .bareModifier(.rightCommand), mode: .toggle, holdThreshold: threshold)
        #expect(g.handle(flags(.rightCommand, at: 0)).contains(.triggerPressed))
        #expect(g.holdThresholdElapsed(at: threshold) == [.begin])
    }
}

// MARK: - Hands-free (double-tap)

private func otherKey(at t: Double, code: UInt16 = 9) -> HotkeyEvent {
    HotkeyEvent(kind: .keyDown, keyCode: code, modifiers: [.rightCommand], timestamp: t)
}

private func handsFreeGesture(mode: TriggerMode = .hold) -> PressGesture {
    PressGesture(binding: rightCommand, mode: mode, holdThreshold: threshold,
                 handsFreeEnabled: true, doubleTapWindow: 0.35, handsFreeLimit: 300)
}

/// A clean tap: down, up 60 ms later, nothing else in between.
private func tap(_ g: inout PressGesture, at t: Double) {
    _ = g.handle(flags(.rightCommand, at: t))
    _ = g.handle(flags([], at: t + 0.06))
}

@Suite("PressGesture — hands-free double-tap")
struct HandsFreeTests {

    @Test("Two clean taps inside the window lock a session open on the second press")
    func doubleTapLocks() {
        var g = handsFreeGesture()
        tap(&g, at: 0)                                   // released at 0.06
        let out = g.handle(flags(.rightCommand, at: 0.20))
        #expect(out == [.triggerPressed, .begin, .handsFreeLocked,
                        .armHandsFreeLimit(deadline: 0.20 + 300)])
        #expect(g.isHandsFree)
        #expect(g.hasActiveSession)
    }

    @Test("Releasing the second press does NOT end the session")
    func releaseOfLockingPressKeepsSessionOpen() {
        var g = handsFreeGesture()
        tap(&g, at: 0)
        _ = g.handle(flags(.rightCommand, at: 0.20))
        #expect(g.handle(flags([], at: 0.28)).isEmpty)
        #expect(g.isHandsFree)
    }

    @Test("Holding the second press for a long time still keeps it hands-free")
    func heldSecondPressStaysLocked() {
        var g = handsFreeGesture()
        tap(&g, at: 0)
        _ = g.handle(flags(.rightCommand, at: 0.20))
        #expect(g.handle(flags([], at: 4.0)).isEmpty)
        #expect(g.isHandsFree)
    }

    @Test("The next press ends a hands-free session, and its release is silent")
    func nextPressEnds() {
        var g = handsFreeGesture()
        tap(&g, at: 0)
        _ = g.handle(flags(.rightCommand, at: 0.20))
        _ = g.handle(flags([], at: 0.28))
        let stop = g.handle(flags(.rightCommand, at: 9.0))
        #expect(stop == [.cancelHandsFreeLimit, .end])
        #expect(!g.hasActiveSession)
        #expect(g.handle(flags([], at: 9.05)).isEmpty)
        // And the gesture is fully usable again afterwards.
        #expect(g.handle(flags(.rightCommand, at: 12)).contains(.triggerPressed))
    }

    @Test("Escape cancels a hands-free session; the next press still works")
    func escapeCancelsHandsFree() {
        var g = handsFreeGesture()
        tap(&g, at: 0)
        _ = g.handle(flags(.rightCommand, at: 0.20))
        _ = g.handle(flags([], at: 0.28))
        #expect(g.handle(escape(at: 3)) == [.cancelHandsFreeLimit, .cancel])
        #expect(!g.hasActiveSession)
        // Not swallowed: the trigger was already up when Escape hit.
        #expect(g.handle(flags(.rightCommand, at: 5)).contains(.triggerPressed))
    }

    @Test("Escape while the locking press is still down swallows exactly that release")
    func escapeWhileLockingPressHeld() {
        var g = handsFreeGesture()
        tap(&g, at: 0)
        _ = g.handle(flags(.rightCommand, at: 0.20))
        #expect(g.handle(escape(at: 0.5)) == [.cancelHandsFreeLimit, .cancel])
        #expect(g.handle(flags([], at: 0.6)).isEmpty)
        #expect(g.handle(flags(.rightCommand, at: 1.0)).contains(.triggerPressed))
    }

    @Test("The safety limit ends the session so the microphone is not left open")
    func limitEnds() {
        var g = handsFreeGesture()
        tap(&g, at: 0)
        _ = g.handle(flags(.rightCommand, at: 0.20))
        _ = g.handle(flags([], at: 0.28))
        #expect(g.handsFreeLimitElapsed() == [.end])
        #expect(!g.hasActiveSession)
        #expect(g.handsFreeLimitElapsed().isEmpty)
    }

    @Test("A second tap after the window is a fresh first tap, not a lock")
    func lateSecondTapDoesNotLock() {
        var g = handsFreeGesture()
        tap(&g, at: 0)                                   // released at 0.06
        let out = g.handle(flags(.rightCommand, at: 0.06 + 0.36))
        #expect(!out.contains(.begin))
        #expect(out.contains(.triggerPressed))
        #expect(!g.isHandsFree)
    }

    @Test("A tap used as a shortcut chord (⌘C) is not the first half of a double-tap")
    func chordedTapDoesNotArm() {
        var g = handsFreeGesture()
        _ = g.handle(flags(.rightCommand, at: 0))
        _ = g.handle(otherKey(at: 0.03))                 // the C in ⌘C
        _ = g.handle(flags([], at: 0.08))
        let out = g.handle(flags(.rightCommand, at: 0.20))   // ⌘V
        #expect(!out.contains(.begin))
        #expect(!g.isHandsFree)
    }

    @Test("Typing between two taps breaks the double-tap")
    func keyBetweenTapsBreaksIt() {
        var g = handsFreeGesture()
        tap(&g, at: 0)
        _ = g.handle(otherKey(at: 0.15))
        let out = g.handle(flags(.rightCommand, at: 0.25))
        #expect(!out.contains(.begin))
    }

    @Test("Hold-to-talk is untouched: a hold still begins and its release still ends")
    func holdStillWorks() {
        var g = handsFreeGesture()
        #expect(pressAndHold(&g).contains(.begin))
        #expect(g.handle(flags([], at: 2)) == [.end])
        #expect(!g.isHandsFree)
    }

    @Test("A tap, then a real hold, is hands-free (second press wins), not a hold session")
    func tapThenHoldIsHandsFree() {
        var g = handsFreeGesture()
        tap(&g, at: 0)
        _ = g.handle(flags(.rightCommand, at: 0.2))
        #expect(g.handle(flags([], at: 1.5)).isEmpty)
        #expect(g.isHandsFree)
    }

    @Test("Disabled by default and in toggle mode: taps never lock")
    func offByDefaultAndInToggle() {
        var plain = makeGesture()                        // handsFreeEnabled false
        tap(&plain, at: 0)
        #expect(!plain.handle(flags(.rightCommand, at: 0.2)).contains(.begin))

        var toggle = handsFreeGesture(mode: .toggle)
        tap(&toggle, at: 0)
        #expect(!toggle.handle(flags(.rightCommand, at: 0.2)).contains(.begin))
    }

    @Test("A stale first tap does not linger: its state is harmless after the window")
    func staleTapIsHarmless() {
        var g = handsFreeGesture()
        tap(&g, at: 0)
        // A long hold well after the window still behaves as a normal hold.
        let out = pressAndHold(&g, pressAt: 30)
        #expect(out.contains(.begin))
        #expect(!g.isHandsFree)
    }
}

@Suite("PressGesture — modifier used as a shortcut key")
struct ChordedHoldTests {

    @Test("Trigger held past the threshold with another key pressed is a shortcut, not a dictation")
    func chordedHoldNeverBegins() {
        var g = makeGesture()
        _ = g.handle(flags(.rightCommand, at: 0))
        _ = g.handle(otherKey(at: 0.04))                  // the V in ⌘V
        let out = g.holdThresholdElapsed(at: threshold)
        #expect(!out.contains(.begin))
        #expect(out == [.cancel], "the provisional pre-roll must be discarded")
        #expect(!g.hasActiveSession)
    }

    @Test("The release of a chorded hold is silent and the gesture recovers")
    func chordedHoldReleaseIsSilent() {
        var g = makeGesture()
        _ = g.handle(flags(.rightCommand, at: 0))
        _ = g.handle(otherKey(at: 0.04))
        _ = g.holdThresholdElapsed(at: threshold)
        #expect(g.handle(flags([], at: 0.4)).isEmpty)
        #expect(pressAndHold(&g, pressAt: 1).contains(.begin), "the next clean hold works")
    }

    @Test("Toggle mode is protected the same way")
    func chordedHoldInToggleMode() {
        var g = makeGesture(mode: .toggle)
        _ = g.handle(flags(.rightCommand, at: 0))
        _ = g.handle(otherKey(at: 0.04))
        #expect(!g.holdThresholdElapsed(at: threshold).contains(.begin))
    }

    @Test("Escape is not a chord key and does not block a hold")
    func escapeIsNotAChord() {
        var g = makeGesture()
        _ = g.handle(flags(.rightCommand, at: 0))
        // Escape before the threshold cancels outright; nothing to begin.
        #expect(g.handle(escape(at: 0.04)) == [.cancelHoldTimer, .cancel])
    }
}
