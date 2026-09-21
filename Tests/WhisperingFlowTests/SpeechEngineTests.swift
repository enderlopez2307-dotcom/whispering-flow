import Foundation
import TextProcessingCore
import Testing
@testable import WhisperingFlowKit

/// Records the lifecycle without touching the Speech framework.
actor FakeSpeechEngine: SpeechEngine {
    enum Call: Equatable { case prepare(String), begin(String), finish, cancel }

    private(set) var calls: [Call] = []
    private(set) var receivedSamples: [Float] = []
    private(set) var sessionOpen = false

    var beginError: (any Error)?
    var finishError: (any Error)?
    var text = "hello world"

    private var consumer: Task<Void, Never>?

    var hasActiveSession: Bool { sessionOpen }

    func prepare(locale: String) async throws { calls.append(.prepare(locale)) }

    func beginSession(locale: String, audio: AsyncStream<[Float]>) async throws {
        guard !sessionOpen else { throw SpeechEngineError.sessionAlreadyActive }
        calls.append(.begin(locale))
        if let beginError { throw beginError }
        sessionOpen = true
        consumer = Task { for await chunk in audio { await self.record(chunk) } }
    }

    private func record(_ chunk: [Float]) { receivedSamples += chunk }

    func finishSession() async throws -> EngineTranscript {
        guard sessionOpen else { throw SpeechEngineError.noSessionActive }
        await consumer?.value
        sessionOpen = false
        calls.append(.finish)
        if let finishError { throw finishError }
        return EngineTranscript(text: text, locale: "en-US", detectedLocale: nil, confidence: nil)
    }

    func cancelSession() async {
        consumer?.cancel()
        sessionOpen = false
        calls.append(.cancel)
    }

    func setText(_ value: String) { text = value }
    func setBeginError(_ error: (any Error)?) { beginError = error }
    func setFinishError(_ error: (any Error)?) { finishError = error }
}

@Suite("Streaming recognition lifecycle (ADR-020)")
struct SpeechStreamingTests {

    @Test("Audio yielded during capture reaches the engine before finish is called")
    func audioStreamsDuringCapture() async throws {
        // This is the whole point of the streaming shape: if the engine only saw
        // audio at finish, key-up latency would include the entire utterance.
        let engine = FakeSpeechEngine()
        let (stream, continuation) = AsyncStream<[Float]>.makeStream()
        try await engine.beginSession(locale: "en-US", audio: stream)

        continuation.yield([0.1, 0.2])
        continuation.yield([0.3])
        continuation.finish()

        let transcript = try await engine.finishSession()
        #expect(await engine.receivedSamples == [0.1, 0.2, 0.3])
        #expect(transcript.text == "hello world")
    }

    @Test("The batch helper feeds the same streaming path")
    func batchGoesThroughStreaming() async throws {
        // One transcription architecture, not two. The corpus harness and the
        // live pipeline must exercise identical code.
        let engine = FakeSpeechEngine()
        let clip = AudioClip(samples: (0..<4_000).map { Float($0) / 4_000 },
                             sampleRate: 16_000, preRollFrameCount: 0)
        _ = try await engine.transcribe(clip, locale: "es-ES")

        #expect(await engine.calls.contains(.begin("es-ES")))
        #expect(await engine.receivedSamples.count == 4_000, "no samples may be dropped in chunking")
        #expect(await engine.receivedSamples == clip.samples)
    }

    @Test("Cancelling produces no transcript and closes the session")
    func cancelProducesNothing() async throws {
        let engine = FakeSpeechEngine()
        let (stream, continuation) = AsyncStream<[Float]>.makeStream()
        try await engine.beginSession(locale: "en-US", audio: stream)
        continuation.yield([0.5])
        await engine.cancelSession()
        continuation.finish()

        #expect(await engine.hasActiveSession == false)
        await #expect(throws: SpeechEngineError.noSessionActive) { try await engine.finishSession() }
    }

    @Test("A second session cannot open while one is active")
    func singleFlightIsExplicit() async throws {
        // Actor isolation alone does NOT give this: actors are reentrant across
        // await, so the guard has to be a real flag (ARCHITECTURE §3.1).
        let engine = FakeSpeechEngine()
        let (first, firstContinuation) = AsyncStream<[Float]>.makeStream()
        try await engine.beginSession(locale: "en-US", audio: first)

        let (second, _) = AsyncStream<[Float]>.makeStream()
        await #expect(throws: SpeechEngineError.sessionAlreadyActive) {
            try await engine.beginSession(locale: "en-US", audio: second)
        }
        firstContinuation.finish()
        _ = try await engine.finishSession()
    }

    @Test("Finishing without a session is an error, not an empty transcript")
    func finishWithoutSession() async {
        let engine = FakeSpeechEngine()
        await #expect(throws: SpeechEngineError.noSessionActive) { try await engine.finishSession() }
    }

    @Test("No previous-session audio survives into the next session")
    func sessionsAreIsolated() async throws {
        let engine = FakeSpeechEngine()
        let clipA = AudioClip(samples: [1, 1, 1], sampleRate: 16_000, preRollFrameCount: 0)
        _ = try await engine.transcribe(clipA, locale: "en-US")
        let carried = await engine.receivedSamples.count

        let clipB = AudioClip(samples: [2, 2], sampleRate: 16_000, preRollFrameCount: 0)
        _ = try await engine.transcribe(clipB, locale: "en-US")
        #expect(await engine.receivedSamples.count == carried + 2,
                "the second session must add exactly its own frames")
    }
}

@Suite("EngineTranscript carries engine output only")
struct EngineTranscriptPurityTests {

    @Test("The engine layer performs no vocabulary or cleanup work")
    func engineDoesNotCleanUp() async throws {
        // Phase 2.5 established vocabulary-before-cleanup wins every divergence.
        // That ordering is only enforceable if the engine never touches text.
        let engine = FakeSpeechEngine()
        await engine.setText("su pae and clock code")
        let clip = AudioClip(samples: [0.1], sampleRate: 16_000, preRollFrameCount: 0)
        let transcript = try await engine.transcribe(clip, locale: "en-US")
        #expect(transcript.text == "su pae and clock code",
                "corrections belong downstream in TextProcessing, not in the engine")
    }

    @Test("Readiness states explain themselves to the user")
    func readinessIsExplicable() {
        #expect(EngineReadiness.ready.isReady)
        #expect(!EngineReadiness.installing(0.5).isReady)
        #expect(EngineReadiness.installing(0.42).description.contains("42%"))
        #expect(EngineReadiness.unsupportedLocale("cy-GB").description.contains("cy-GB"))
        for state: EngineReadiness in [.unknown, .notInstalled, .installing(0), .ready,
                                       .unsupportedLocale("x")] {
            #expect(!state.description.isEmpty, "a blocking state with no explanation looks like a hang")
        }
    }
}

// MARK: - Coordinator integration

@Suite("Recognition is orchestrated by the coordinator")
@MainActor
struct RecognitionOrchestrationTests {

    @Test("Recognition starts at begin, not at release")
    func recognitionStartsAtBegin() async {
        let audio = FakeAudioCapture()
        let hotkey = FakeHotkeyMonitor()
        let speech = FakeSpeechEngine()
        let coordinator = makeCoordinator(audio: audio, hotkey: hotkey, speech: speech)
        coordinator.start()

        hotkey.onTriggerPressed?()
        hotkey.onPress?()
        // Give the begin task a turn.
        for _ in 0..<10 { await Task.yield() }

        #expect(await speech.hasActiveSession,
                "starting only at release would throw away Apple's streaming advantage")
        #expect(await speech.calls.contains(.begin("en-US")))
    }

    @Test("Pre-roll audio reaches the engine ahead of the rest")
    func preRollIsStreamedFirst() async throws {
        let audio = FakeAudioCapture()
        let hotkey = FakeHotkeyMonitor()
        let speech = FakeSpeechEngine()
        let coordinator = makeCoordinator(audio: audio, hotkey: hotkey, speech: speech)
        coordinator.start()

        hotkey.onTriggerPressed?()
        hotkey.onPress?()
        for _ in 0..<10 { await Task.yield() }

        audio.feed?.yield([0.1, 0.2])
        audio.feed?.yield([0.3])
        hotkey.onRelease?()
        for _ in 0..<20 { await Task.yield() }

        #expect(await speech.receivedSamples == [0.1, 0.2, 0.3])
    }

    @Test("Escape cancels recognition, so no transcript is produced")
    func escapeCancelsRecognition() async {
        let audio = FakeAudioCapture()
        let hotkey = FakeHotkeyMonitor()
        let speech = FakeSpeechEngine()
        let coordinator = makeCoordinator(audio: audio, hotkey: hotkey, speech: speech)
        coordinator.start()

        hotkey.onTriggerPressed?()
        hotkey.onPress?()
        for _ in 0..<10 { await Task.yield() }
        hotkey.onCancel?()
        for _ in 0..<20 { await Task.yield() }

        #expect(await speech.calls.contains(.cancel))
        #expect(!(await speech.calls.contains(.finish)),
                "a cancelled session must never be finalised — that text was refused")
        #expect(coordinator.state == .idle)
        #expect(coordinator.recovery.latest == nil, "nothing may be recorded for a cancelled session")
    }

    @Test("No speech detected produces no downstream text")
    func noSpeechProducesNothing() async {
        let audio = FakeAudioCapture()
        let hotkey = FakeHotkeyMonitor()
        let speech = FakeSpeechEngine()
        await speech.setFinishError(SpeechEngineError.noSpeechDetected)
        let coordinator = makeCoordinator(audio: audio, hotkey: hotkey, speech: speech)
        coordinator.start()

        hotkey.fullHold()
        for _ in 0..<30 { await Task.yield() }

        #expect(coordinator.recovery.latest == nil, "an empty result must not become a transcript")
        #expect(coordinator.state.canStartSession)
    }

    @Test("A transcription failure does not wedge the coordinator")
    func failureDoesNotWedge() async {
        let audio = FakeAudioCapture()
        let hotkey = FakeHotkeyMonitor()
        let speech = FakeSpeechEngine()
        await speech.setFinishError(SpeechEngineError.analyzerUnavailable("boom"))
        let coordinator = makeCoordinator(audio: audio, hotkey: hotkey, speech: speech)
        coordinator.start()

        hotkey.fullHold()
        for _ in 0..<30 { await Task.yield() }
        #expect(coordinator.state.canStartSession)
        #expect(!coordinator.state.isBusy)
    }

    @Test("The next dictation succeeds after a failure")
    func recoversAfterFailure() async {
        let audio = FakeAudioCapture()
        let hotkey = FakeHotkeyMonitor()
        let speech = FakeSpeechEngine()
        await speech.setFinishError(SpeechEngineError.analyzerUnavailable("boom"))
        let coordinator = makeCoordinator(audio: audio, hotkey: hotkey, speech: speech)
        coordinator.start()

        hotkey.fullHold()
        for _ in 0..<30 { await Task.yield() }

        await speech.setFinishError(nil)
        await speech.setText("second attempt")
        hotkey.fullHold()
        for _ in 0..<30 { await Task.yield() }

        #expect(coordinator.recovery.latest?.text == "second attempt")
    }

    @Test("No previous-session text appears in a later transcript")
    func noTextContamination() async {
        let audio = FakeAudioCapture()
        let hotkey = FakeHotkeyMonitor()
        let speech = FakeSpeechEngine()
        await speech.setText("first utterance")
        let coordinator = makeCoordinator(audio: audio, hotkey: hotkey, speech: speech)
        coordinator.start()

        hotkey.fullHold()
        for _ in 0..<30 { await Task.yield() }
        #expect(coordinator.recovery.latest?.text == "first utterance")

        await speech.setText("second utterance")
        hotkey.fullHold()
        for _ in 0..<30 { await Task.yield() }
        let latest = coordinator.recovery.latest?.text
        #expect(latest == "second utterance")
        #expect(latest?.contains("first") == false, "the previous transcript must not be carried forward")
    }

    @Test("Switching language mid-session changes the locale sent to the engine")
    func localeSwitchNeedsNoRestart() async {
        // EN → ES → EN. Both locales are reserved at launch (Phase 2.5 Q1), so
        // this must not require a relaunch.
        let audio = FakeAudioCapture()
        let hotkey = FakeHotkeyMonitor()
        let speech = FakeSpeechEngine()
        let coordinator = makeCoordinator(audio: audio, hotkey: hotkey, speech: speech)
        coordinator.start()

        hotkey.fullHold()
        for _ in 0..<30 { await Task.yield() }

        coordinator.debugSetLocale(.spanishES)
        hotkey.fullHold()
        for _ in 0..<30 { await Task.yield() }

        coordinator.debugSetLocale(.englishUS)
        hotkey.fullHold()
        for _ in 0..<30 { await Task.yield() }

        let begins = await speech.calls.compactMap { call -> String? in
            if case .begin(let locale) = call { return locale }
            return nil
        }
        #expect(begins == ["en-US", "es-ES", "en-US"])
    }
}

// MARK: - Smart mode safety

@Suite("Smart mode never loses the transcript")
struct SmartCleanupSafetyTests {

    @Test("Conversational packaging is unwrapped")
    func unwrapsChatReplies() {
        // Observed only under repeated-run testing: the model intermittently
        // ignores "output only the cleaned text" and replies like an assistant.
        let raw = "Sure, here is the cleaned-up transcript:\n```\nDeploy the service.\n```"
        #expect(SmartCleanup.sanitize(raw, against: "deploy the service")
                == .accepted("Deploy the service."))
    }

    @Test("A code fence never survives into accepted text")
    func fencesNeverReachTheDocument() {
        // The invariant that matters: pasting a code fence into the user's
        // document is far worse than leaving a recognition error in. An
        // unterminated fence is unwrapped; anything still fenced is rejected.
        let malformed = [
            "```\nhalf a fence",
            "```text\nDeploy it.\n```",
            "Here you go:\n```\nDeploy it.\n```",
            "``` a ``` b ``` c",
        ]
        for raw in malformed {
            if case .accepted(let text) = SmartCleanup.sanitize(raw, against: "deploy it") {
                #expect(!text.contains("```"), "a fence reached accepted output: \(text)")
            }
        }
    }

    @Test("Wrapping quotes are stripped")
    func stripsQuotes() {
        #expect(SmartCleanup.sanitize("\"Hello there.\"", against: "hello there")
                == .accepted("Hello there."))
    }

    @Test("Text that grew or shrank dramatically is rejected")
    func rejectsLengthSwings() {
        let input = String(repeating: "word ", count: 40)
        // Expansion means it invented content.
        if case .rejected = SmartCleanup.sanitize(input + input, against: input) {}
        else { Issue.record("a 2× expansion must be rejected") }
        // Contraction means it summarised, dropping what the user said.
        if case .rejected = SmartCleanup.sanitize("word", against: input) {}
        else { Issue.record("a summary must be rejected") }
    }

    @Test("An empty model response is rejected")
    func rejectsEmpty() {
        if case .rejected = SmartCleanup.sanitize("   ", against: "some real text") {}
        else { Issue.record("empty output must be rejected") }
    }

    @Test("A reasonable cleanup is accepted")
    func acceptsGoodOutput() {
        #expect(SmartCleanup.sanitize("Deploy the Supabase function.",
                                      against: "deploy the supabase function")
                == .accepted("Deploy the Supabase function."))
    }

    @Test("Refusals are recognised in both languages")
    func recognisesRefusals() {
        for refusal in ["I'm sorry, I can't help with that", "I cannot assist with this request",
                        "Lo siento, no puedo ayudarte", "No puedo procesar esto"] {
            #expect(SmartCleanup.looksLikeRefusal(refusal), "missed refusal: \(refusal)")
        }
        #expect(!SmartCleanup.looksLikeRefusal("I cannot wait to deploy this"),
                "a transcript that merely starts with 'I cannot' is not a refusal")
    }

    @Test("Spanish instructions are written in Spanish")
    func spanishInstructionsAreSpanish() {
        // An English block saying "NEVER TRANSLATE" did not stop the model
        // translating Spanish transcripts (benchmark #13, #14). Addressing it
        // in the target language is what held: 3/18 hard failures → 1/18.
        #expect(SmartCleanup.instructionsES.contains("español"))
        #expect(SmartCleanup.instructionsES.contains("Nunca traduzcas"))
        #expect(!SmartCleanup.instructionsES.contains("NEVER TRANSLATE"))
    }
}

@Suite("Processing order is locked (ADR-021)")
struct ProcessingOrderTests {

    private func processor(_ rules: [VocabularyRule]) -> ProductionTextProcessor {
        ProductionTextProcessor(vocabulary: { rules })
    }

    @Test("Vocabulary runs before cleanup, so capitalisation sees the right names")
    func vocabularyBeforeCleanup() async {
        let result = await processor(DefaultVocabulary.seed()).process(
            EngineTranscript(text: "deploy the superbase function with cloud code",
                             locale: "en-US", detectedLocale: nil, confidence: nil),
            smart: false)
        #expect(result.contains("Supabase"))
        #expect(result.contains("Claude Code"))
        #expect(result.hasPrefix("Deploy"))
    }

    @Test("Vocabulary output is never rewritten by a second vocabulary pass")
    func vocabularyRunsOnce() async {
        // Field bug, 19 Sept 2026: `claude md → CLAUDE.md` was correct after the
        // vocabulary step, then the pipeline's own vocabulary stage ran again and
        // `claude → Claude` turned it into "Claude.md".
        let rules = [VocabularyRule(spoken: "claude", replacement: "Claude"),
                     VocabularyRule(spoken: "claude md", replacement: "CLAUDE.md")]
        let result = await processor(rules).process(
            EngineTranscript(text: "read claude md and ask claude",
                             locale: "en-US", detectedLocale: nil, confidence: nil),
            smart: false)
        #expect(result.contains("CLAUDE.md"))
        #expect(!result.contains("Claude.md"))
        #expect(result.contains("ask Claude"))
    }

    @Test("Fast mode makes no model call and is deterministic")
    func fastModeIsPure() async {
        let engine = EngineTranscript(text: "um deploy the superbase thing",
                                      locale: "en-US", detectedLocale: nil, confidence: nil)
        let processor = processor(DefaultVocabulary.seed())
        let first = await processor.process(engine, smart: false)
        for _ in 0..<10 {
            #expect(await processor.process(engine, smart: false) == first)
        }
    }

    @Test("Spanish transcripts get the Spanish stage configuration")
    func localeRoutingWorks() async {
        let result = await processor(DefaultVocabulary.seed()).process(
            EngineTranscript(text: "quiero que revises este archivo",
                             locale: "es-ES", detectedLocale: nil, confidence: nil),
            smart: false)
        // `este` is a demonstrative here and must survive (benchmark #14).
        #expect(result.contains("este archivo"))
    }
}

@Suite("Processing runs off the main actor without trapping")
struct ProcessorIsolationTests {

    @Test("The processor works when called from a non-main executor")
    func processFromBackgroundExecutor() async {
        // `TextProcessing.process` is a non-isolated async requirement, so the
        // real pipeline calls it from the cooperative pool. An earlier version
        // reached the vocabulary store with `MainActor.assumeIsolated` and took
        // SIGTRAP on the first real dictation — the app died before inserting a
        // single character, and no unit test noticed because they all ran on the
        // main actor.
        let store = await MainActor.run {
            VocabularyStore(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("vocab-test-\(UUID().uuidString)"),
                            defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        }
        let processor = ProductionTextProcessor(
            vocabulary: { store.activeRules },
            onTrace: { _ in })

        let result = await Task.detached {
            // A detached task never inherits the main actor, which is what
            // makes this exercise the executor the real pipeline uses.
            return await processor.process(
                EngineTranscript(text: "deploy the superbase function with cloud code",
                                 locale: "en-US", detectedLocale: nil, confidence: nil),
                smart: false)
        }.value

        #expect(result.contains("Supabase"))
        #expect(result.contains("Claude Code"))
    }

    @Test("The trace callback also survives being invoked off the main actor")
    func traceFromBackgroundExecutor() async {
        let box = TraceCollector()
        let processor = ProductionTextProcessor(vocabulary: { [] },
                                                onTrace: { box.store($0) })
        _ = await Task.detached {
            await processor.process(
                EngineTranscript(text: "hello there", locale: "en-US",
                                 detectedLocale: nil, confidence: nil),
                smart: false)
        }.value
        #expect(await box.received != nil)
    }
}

@MainActor
private final class TraceCollector {
    var received: ProductionTextProcessor.Trace?
    func store(_ trace: ProductionTextProcessor.Trace) { received = trace }
}
