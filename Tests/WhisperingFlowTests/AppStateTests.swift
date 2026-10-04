import Foundation
import HotkeyGestureCore
import Testing
@testable import WhisperingFlowKit

@Suite("Transcript recovery — ADR-015")
@MainActor
struct TranscriptRecoveryTests {

    @Test("A recorded transcript is immediately recoverable")
    func recordedIsRecoverable() {
        let recovery = TranscriptRecovery()
        let id = recovery.record(text: "hello", locale: "en-US")
        #expect(recovery.latest?.id == id)
        #expect(recovery.latestUnrecovered?.text == "hello")
        #expect(recovery.latest?.outcome == .pending)
    }

    @Test("A successfully inserted transcript stops being 'unrecovered'")
    func insertedIsNotUnrecovered() {
        let recovery = TranscriptRecovery()
        let id = recovery.record(text: "hello", locale: "en-US")
        recovery.markOutcome(id, .inserted)
        #expect(recovery.latestUnrecovered == nil)
        #expect(recovery.latest?.isRecoverable == false)
    }

    @Test("A failed insertion leaves the transcript recoverable with a reason")
    func failedInsertionStaysRecoverable() {
        let recovery = TranscriptRecovery()
        let id = recovery.record(text: "important words", locale: "en-US")
        recovery.markOutcome(id, .insertionFailed, detail: "Secure input active")
        let entry = recovery.latestUnrecovered
        #expect(entry?.text == "important words")
        #expect(entry?.failureDetail == "Secure input active")
        #expect(entry?.isRecoverable == true)
    }

    @Test("The most recent unrecovered entry wins over a newer successful one")
    func unrecoveredIsFoundBehindSuccesses() {
        let recovery = TranscriptRecovery()
        let stranded = recovery.record(text: "stranded", locale: "en-US")
        recovery.markOutcome(stranded, .insertionFailed)
        let ok = recovery.record(text: "delivered", locale: "en-US")
        recovery.markOutcome(ok, .inserted)
        #expect(recovery.latest?.text == "delivered")
        #expect(recovery.latestUnrecovered?.text == "stranded")
    }

    @Test("History is bounded so transcripts do not accumulate forever")
    func historyIsBounded() {
        let recovery = TranscriptRecovery(limit: 3)
        for index in 0..<10 {
            recovery.record(text: "entry \(index)", locale: "en-US")
        }
        #expect(recovery.history.count == 3)
        #expect(recovery.history.first?.text == "entry 9")
    }

    @Test("Copying an unknown id fails rather than copying the wrong thing")
    func copyingUnknownIDFails() {
        let recovery = TranscriptRecovery()
        #expect(recovery.copyToPasteboard(UUID()) == false)
    }
}

@Suite("Session state machine")
struct SessionStateTests {

    @Test("Only idle and failed can start a new session")
    func startableStates() {
        #expect(SessionState.idle.canStartSession)
        #expect(SessionState.failed(.noSpeechDetected).canStartSession)
        #expect(!SessionState.listening(startedAt: Date()).canStartSession)
        #expect(!SessionState.transcribing.canStartSession)
        #expect(!SessionState.processing.canStartSession)
        #expect(!SessionState.inserting.canStartSession)
        #expect(!SessionState.blocked(.secureInput(holder: nil)).canStartSession)
    }

    @Test("A previous failure must not wedge the app")
    func failureDoesNotWedge() {
        // Regression guard: if .failed ever stops being startable, one bad
        // insertion would make the app permanently unusable until relaunch.
        #expect(SessionState.failed(.insertionFailed("x")).canStartSession)
    }

    @Test("Busy states are exactly the in-flight ones")
    func busyStates() {
        #expect(SessionState.listening(startedAt: Date()).isBusy)
        #expect(SessionState.transcribing.isBusy)
        #expect(SessionState.processing.isBusy)
        #expect(SessionState.inserting.isBusy)
        #expect(!SessionState.idle.isBusy)
        #expect(!SessionState.blocked(.secureInput(holder: nil)).isBusy)
        #expect(!SessionState.failed(.noSpeechDetected).isBusy)
    }

    @Test("Only insertion failure implies a transcript may survive")
    func onlyInsertionFailureKeepsTranscript() {
        #expect(FailureReason.insertionFailed("x").mayHaveTranscript)
        #expect(!FailureReason.noSpeechDetected.mayHaveTranscript)
        #expect(!FailureReason.transcriptionFailed("x").mayHaveTranscript)
        #expect(!FailureReason.audioUnavailable("x").mayHaveTranscript)
    }

    @Test("Every block and failure reason has a non-empty title and detail")
    func reasonsAreExplained() {
        let blocks: [BlockReason] = [
            .missingPermissions([.microphone]),
            .missingPermissions([.microphone, .accessibility]),
            .secureInput(holder: "Terminal"),
            .secureInput(holder: nil),
        ]
        for reason in blocks {
            #expect(!reason.title.isEmpty)
            #expect(!reason.detail.isEmpty)
        }
        let failures: [FailureReason] = [
            .audioUnavailable("a"), .transcriptionFailed("b"),
            .noSpeechDetected, .insertionFailed("c"),
        ]
        for reason in failures {
            #expect(!reason.title.isEmpty)
            #expect(!reason.detail.isEmpty)
        }
    }
}

@Suite("Settings persistence")
@MainActor
struct SettingsStoreTests {

    private func makeDefaults() -> UserDefaults {
        let suite = "wf.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("A fresh store yields the documented defaults")
    func freshDefaults() {
        let store = SettingsStore(defaults: makeDefaults())
        #expect(store.preferences == .default)
        #expect(store.preferences.processingMode == .fast)
        #expect(store.preferences.hotkey == .bareModifier(.rightCommand))
    }

    @Test("Preferences survive a store being recreated — the restart case")
    func preferencesPersist() {
        let defaults = makeDefaults()
        let first = SettingsStore(defaults: defaults)
        first.preferences.processingMode = .smart
        first.preferences.locale = .spanishES
        first.preferences.hotkey = .key(keyCode: 97, required: [])   // F6
        first.preferences.triggerMode = .toggle
        first.preferences.playFeedbackSounds = false

        let second = SettingsStore(defaults: defaults)
        #expect(second.preferences.processingMode == .smart)
        #expect(second.preferences.locale == .spanishES)
        #expect(second.preferences.hotkey == .key(keyCode: 97, required: []))
        #expect(second.preferences.triggerMode == .toggle)
        #expect(second.preferences.playFeedbackSounds == false)
    }

    @Test("Automatic language survives a restart, and English stays the default")
    func automaticLanguagePersists() {
        let defaults = makeDefaults()
        #expect(SettingsStore(defaults: defaults).preferences.locale == .englishUS)
        SettingsStore(defaults: defaults).preferences.locale = .automatic
        #expect(SettingsStore(defaults: defaults).preferences.locale == .automatic)
        // The engine recognises the setting's raw value as its automatic mode.
        #expect(Preferences.DictationLocale.automatic.rawValue == AppleSpeechEngine.automaticLocale)
    }

    @Test("A bare-modifier hotkey round-trips, left/right preserved")
    func bareModifierRoundTrips() {
        let defaults = makeDefaults()
        let first = SettingsStore(defaults: defaults)
        first.preferences.hotkey = .bareModifier(.rightOption)
        let second = SettingsStore(defaults: defaults)
        #expect(second.preferences.hotkey == .bareModifier(.rightOption))
        // Left and right must not be conflated — the whole reason for the event tap.
        #expect(second.preferences.hotkey != .bareModifier(.leftOption))
    }

    @Test("Reset restores defaults and persists that")
    func resetPersists() {
        let defaults = makeDefaults()
        let store = SettingsStore(defaults: defaults)
        store.preferences.locale = .spanishES
        store.reset()
        #expect(SettingsStore(defaults: defaults).preferences == .default)
    }
}

@Suite("Hotkey binding is configuration, not hardcoded")
struct HotkeyConfigurationTests {

    @Test("Several bindings are selectable, including F-keys")
    func selectableBindings() {
        #expect(HotkeyBinding.selectable.count >= 4)
        #expect(HotkeyBinding.selectable.contains(.bareModifier(.rightCommand)))
        // F6. Phase 4 replaced F13 here: the target keyboard has F1–F12 only.
        #expect(HotkeyBinding.selectable.contains(.key(keyCode: 97, required: [])))
    }

    @Test("Every selectable binding renders a human name")
    func allSelectableRender() {
        for binding in HotkeyBinding.selectable {
            let name = binding.displayName
            #expect(!name.isEmpty)
            #expect(!name.hasPrefix("Key "))   // no raw keycodes leaking to the UI
        }
    }

    @Test("Left and right modifiers are distinguishable in the UI")
    func leftRightDistinguished() {
        #expect(HotkeyBinding.bareModifier(.rightCommand).displayName == "Right Command")
        #expect(HotkeyBinding.bareModifier(.leftCommand).displayName == "Left Command")
    }
}
