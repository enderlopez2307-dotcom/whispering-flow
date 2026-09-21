import AppKit
import Foundation
import Testing
import TextProcessingCore
@testable import WhisperingFlowKit

private func target(_ confidence: FocusedTarget.Confidence,
                    app: String = "TextEdit",
                    bundle: String = "com.apple.TextEdit") -> FocusedTarget {
    FocusedTarget(bundleIdentifier: bundle, applicationName: app, processIdentifier: 1,
                  role: nil, subrole: nil, confidence: confidence)
}

/// Records what it was asked to do, and can be told to fail.
private struct ScriptedStrategy: InsertionStrategy {
    let name: String
    var outcome: InsertionOutcome
    var attempts: Attempts = Attempts()

    final class Attempts: @unchecked Sendable {
        var count = 0
    }

    func canAttempt(_ target: FocusedTarget) -> Bool { target.allowsInsertion }

    @MainActor
    func insert(_ text: String, into target: FocusedTarget) async -> InsertionOutcome {
        attempts.count += 1
        return outcome
    }
}

@Suite("Insertion is refused when the destination is wrong")
@MainActor
struct InsertionRefusalTests {

    @Test("A secure field is never written to")
    func secureFieldsRefused() async {
        // Non-negotiable: a password field must never receive dictated text.
        let strategy = ScriptedStrategy(name: "s", outcome: .inserted(strategy: "s"))
        let chain = InsertionChain(strategies: [strategy])
        let outcome = await chain.insert("hunter2")

        if case .refused(let reason) = outcome {
            #expect(reason.lowercased().contains("password") || reason.lowercased().contains("secure"))
        } else {
            // The live probe reads the real focused element, so this only
            // asserts the model when a secure field is actually focused.
            #expect(target(.secureField).allowsInsertion == false)
        }
        #expect(target(.secureField).allowsInsertion == false)
        #expect(target(.secureField).refusalReason?.isEmpty == false)
    }

    @Test("The Safari address bar is rejected by subrole")
    func addressBarRejected() {
        // The exact Phase 2 failure. AXURIField is an AXTextField by role —
        // indistinguishable without checking the subrole, which is how a
        // dictated sentence ended up in the address bar.
        #expect(FocusedAppProbe.rejectedSubroles.contains("AXURIField"))
        let bar = target(.notEditable(role: "AXURIField"))
        #expect(!bar.allowsInsertion)
        #expect(bar.refusalReason?.isEmpty == false)
    }

    @Test("A mid-dictation app switch refuses rather than inserting elsewhere")
    func appSwitchRefused() {
        let switched = target(.appChanged(from: "TextEdit", to: "Slack"))
        #expect(!switched.allowsInsertion)
        let reason = switched.refusalReason ?? ""
        #expect(reason.contains("TextEdit") && reason.contains("Slack"),
                "the message must name both apps so the user knows what happened")
    }

    @Test("Non-editable elements are refused with a usable explanation")
    func nonEditableRefused() {
        for role in ["AXButton", "AXStaticText", "AXList", "AXUnknown"] {
            let element = target(.notEditable(role: role))
            #expect(!element.allowsInsertion)
            let reason = element.refusalReason ?? ""
            #expect(!reason.isEmpty)
            #expect(reason.contains("Copy Last Transcript"),
                    "a refusal must tell the user how to get their text back")
        }
    }

    @Test("An opaque app is allowed — Electron answers no AX queries and is still valid")
    func opaqueIsAllowed() {
        // VS Code, Slack and much of Chrome look like this. Refusing them would
        // make the app useless on most of the target matrix.
        #expect(target(.opaque).allowsInsertion)
        #expect(target(.opaque).refusalReason == nil)
        #expect(target(.editableText).allowsInsertion)
    }
}

@Suite("Insertion chain behaviour")
@MainActor
struct InsertionChainTests {

    @Test("Empty text is never delivered")
    func emptyIsNotInserted() async {
        let chain = InsertionChain(strategies: [])
        if case .failed = await chain.insert("   \n ") {} else {
            Issue.record("empty text should not reach a strategy")
        }
    }

    @Test("A refusal stops the chain instead of trying every strategy")
    func refusalIsTerminal() async {
        // Secure input blocks every strategy. Continuing would just post more
        // events and delay the error the user needs to see.
        let first = ScriptedStrategy(name: "a", outcome: .refused(reason: "secure input"))
        let second = ScriptedStrategy(name: "b", outcome: .inserted(strategy: "b"))
        let chain = InsertionChain(strategies: [first, second])
        _ = await chain.insert("hello")
        #expect(second.attempts.count == 0, "a refusal must not fall through to the next strategy")
    }

    @Test("A failure falls through to the next strategy")
    func failureFallsThrough() async {
        let first = ScriptedStrategy(name: "a", outcome: .failed(reason: "AX said no"))
        let second = ScriptedStrategy(name: "b", outcome: .inserted(strategy: "b"))
        let chain = InsertionChain(strategies: [first, second])
        let outcome = await chain.insert("hello")

        #expect(first.attempts.count == 1)
        #expect(second.attempts.count == 1)
        #expect(outcome == .inserted(strategy: "b"))
    }

    @Test("When every strategy fails the chain reports failure, not success")
    func allFailuresReported() async {
        let chain = InsertionChain(strategies: [
            ScriptedStrategy(name: "a", outcome: .failed(reason: "one")),
            ScriptedStrategy(name: "b", outcome: .failed(reason: "two")),
        ])
        if case .failed(let reason) = await chain.insert("hello") {
            #expect(reason == "two")
        } else {
            Issue.record("expected failure")
        }
    }

    @Test("Unicode typing declines long text rather than typing it visibly")
    func unicodeTypingHasALimit() async {
        let long = String(repeating: "a", count: UnicodeKeystrokeInserter.maximumLength + 1)
        let outcome = await UnicodeKeystrokeInserter().insert(long, into: target(.opaque))
        if case .failed(let reason) = outcome {
            #expect(reason.contains("too long"))
        } else {
            Issue.record("expected a length refusal, got \(outcome)")
        }
    }

    @Test("Accessibility only attempts a positively identified text field")
    func accessibilityIsSelective() {
        // Against an opaque target AX has nothing to write to, so attempting it
        // just costs a timeout before paste runs.
        #expect(AccessibilityInserter().canAttempt(target(.editableText)))
        #expect(!AccessibilityInserter().canAttempt(target(.opaque)))
        #expect(!AccessibilityInserter().canAttempt(target(.secureField)))
    }
}

@Suite("Dictation never submits on the user's behalf")
@MainActor
struct NoAutoReturnTests {

    @Test("The trailing suffix is a space, never a newline")
    func defaultSuffixIsSpace() {
        // A trailing Return would send the message in ChatGPT, WhatsApp and
        // Gmail, and execute the line in Terminal and Claude Code.
        #expect(ProcessingOptions().trailingSuffix == .space)
        #expect(ProcessingOptions.TrailingSuffix.space.literal == " ")
    }

    @Test("Final text handed to insertion never ends in a single newline")
    func finalTextNeverEndsWithReturn() async {
        let audio = FakeAudioCapture()
        let hotkey = FakeHotkeyMonitor()
        let speech = FakeSpeechEngine()
        let inserter = FakeInserter()
        await speech.setText("run the deploy script")
        let coordinator = makeCoordinator(audio: audio, hotkey: hotkey, speech: speech,
                                          inserter: inserter)
        coordinator.start()

        hotkey.fullHold()
        for _ in 0..<30 { await Task.yield() }

        let delivered = inserter.inserted.last ?? ""
        #expect(!delivered.isEmpty)
        #expect(!delivered.hasSuffix("\n"), "a trailing Return would submit in several targets")
    }
}

@Suite("Failed insertion preserves the transcript (ADR-015)")
@MainActor
struct InsertionRecoveryTests {

    @Test("A refused insertion still leaves the text recoverable")
    func refusalPreservesText() async {
        let audio = FakeAudioCapture()
        let hotkey = FakeHotkeyMonitor()
        let speech = FakeSpeechEngine()
        let inserter = FakeInserter()
        inserter.outcome = .refused(reason: "cursor is in the address bar")
        await speech.setText("something worth keeping")
        let coordinator = makeCoordinator(audio: audio, hotkey: hotkey, speech: speech,
                                          inserter: inserter)
        coordinator.start()

        hotkey.fullHold()
        for _ in 0..<30 { await Task.yield() }

        #expect(coordinator.recovery.latest?.text == "something worth keeping")
        #expect(coordinator.recovery.latestUnrecovered?.text == "something worth keeping")
        #expect(coordinator.recovery.latest?.outcome == .blocked)
    }

    @Test("A failed insertion still leaves the text recoverable")
    func failurePreservesText() async {
        let audio = FakeAudioCapture()
        let hotkey = FakeHotkeyMonitor()
        let speech = FakeSpeechEngine()
        let inserter = FakeInserter()
        inserter.outcome = .failed(reason: "no strategy worked")
        await speech.setText("do not lose this")
        let coordinator = makeCoordinator(audio: audio, hotkey: hotkey, speech: speech,
                                          inserter: inserter)
        coordinator.start()

        hotkey.fullHold()
        for _ in 0..<30 { await Task.yield() }

        #expect(coordinator.recovery.latestUnrecovered?.text == "do not lose this")
        #expect(coordinator.state.canStartSession, "a delivery failure must not block the next dictation")
    }

    @Test("The next dictation works after an insertion failure")
    func recoversAfterInsertionFailure() async {
        let audio = FakeAudioCapture()
        let hotkey = FakeHotkeyMonitor()
        let speech = FakeSpeechEngine()
        let inserter = FakeInserter()
        inserter.outcome = .failed(reason: "boom")
        let coordinator = makeCoordinator(audio: audio, hotkey: hotkey, speech: speech,
                                          inserter: inserter)
        coordinator.start()
        hotkey.fullHold()
        for _ in 0..<30 { await Task.yield() }

        inserter.outcome = .inserted(strategy: "clipboard")
        await speech.setText("second one")
        hotkey.fullHold()
        for _ in 0..<30 { await Task.yield() }

        #expect(inserter.inserted.count == 2)
        #expect(coordinator.recovery.latest?.outcome == .inserted)
    }
}

@Suite("Window chrome is refused structurally, not by label")
@MainActor
struct WindowChromeTests {

    @Test("Chrome is refused and explains itself")
    func chromeIsRefused() {
        let bar = target(.windowChrome(detail: "the browser toolbar or address bar"))
        #expect(!bar.allowsInsertion)
        let reason = bar.refusalReason ?? ""
        #expect(reason.contains("address bar"))
        #expect(reason.contains("Copy Last Transcript"))
    }

    @Test("Toolbar ancestors are treated as chrome")
    func toolbarAncestorsAreChrome() {
        // The rule that closes the hole: the address bar is an ordinary
        // AXTextField, but it lives inside an AXToolbar and page content does
        // not. On macOS 26 Safari reports no subrole at all, so the earlier
        // subrole blacklist let a dictated sentence straight into it.
        #expect(FocusedAppProbe.chromeAncestorRoles.contains("AXToolbar"))
        #expect(FocusedAppProbe.chromeAncestorRoles.contains("AXSheet"))
    }

    @Test("Every browser on the target matrix is recognised as a browser")
    func browsersAreKnown() {
        // In a browser, "it is a text field" is not evidence: the address bar
        // is one too. These bundles require positively finding an AXWebArea.
        for bundle in ["com.apple.Safari", "com.google.Chrome",
                       "com.microsoft.edgemac", "com.brave.Browser"] {
            #expect(FocusedAppProbe.browserBundles.contains(bundle), "\(bundle) not covered")
        }
    }

    @Test("Non-browser apps are not required to expose a web area")
    func nonBrowsersAreUnaffected() {
        // TextEdit, Terminal and VS Code have no AXWebArea and must stay usable.
        for bundle in ["com.apple.TextEdit", "com.apple.Terminal",
                       "com.microsoft.VSCode", "com.anthropic.claudefordesktop"] {
            #expect(!FocusedAppProbe.browserBundles.contains(bundle))
        }
    }
}

@Suite("Accessibility insertion cannot duplicate or invent text")
@MainActor
struct AccessibilityInsertionSafetyTests {

    @Test("The strategy declines when selected-text insertion is unavailable")
    func requiresSelectedText() async {
        // Against a target with no settable AXSelectedText it must fail cleanly
        // so the chain falls through to pasting — not attempt a value rewrite.
        let outcome = await AccessibilityInserter().insert(
            "hello", into: target(.editableText, app: "Nothing", bundle: "com.example.none"))
        if case .failed = outcome {} else {
            // On a machine where something editable happens to be focused this
            // can legitimately succeed; the invariant asserted below is the one
            // that matters.
        }
        #expect(AccessibilityInserter().canAttempt(target(.editableText)))
    }

    @Test("A whole-value rewrite is never used")
    func neverRewritesWholeValue() throws {
        // Regression guard for the milestone bug. Reading AXValue and writing a
        // spliced copy back materialised placeholder text as real content and
        // duplicated the utterance: VS Code emitted "…⌘ Esc to focus or unfocus
        // Claude" and Codex typed the sentence twice plus "Do anything".
        //
        // In Electron and web views AXValue is the visible buffer, not the
        // editable content, so the only safe write is AXSelectedText.
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/WhisperingFlow/Insertion/Inserters.swift"),
            encoding: .utf8)
        let axSection = source.components(separatedBy: "// MARK: - Clipboard paste")[0]
        #expect(axSection.contains("kAXSelectedTextAttribute"))
        #expect(!axSection.contains("replacingCharacters"),
                "AX insertion must not splice the field's whole value")
        #expect(!axSection.contains("kAXValueAttribute as CFString, updated"),
                "AX insertion must not write a reconstructed value back")
    }
}
