import AppKit
import Foundation
import HotkeyGestureCore
import Observation

/// The state machine, and the only type that sees the whole graph.
///
/// Services never call each other; everything routes through here. That is what
/// makes the two invariants enforceable in one place:
///
/// 1. **Single flight.** Never two transcriptions at once. A Swift `actor` is
///    NOT sufficient — actors are reentrant at suspension points, so a second
///    call can enter while `await transcribe(...)` is suspended
///    (TECH_RESEARCH §5.1). The guard has to sit above the engine.
/// 2. **Never lose text (ADR-015).** The transcript is recorded before insertion
///    is attempted, so every downstream failure still leaves it recoverable.
@MainActor
@Observable
final class DictationCoordinator {

    private(set) var state: SessionState = .idle
    private(set) var currentSession: DictationSession?
    /// The running session was locked open by a double-tap, so the UI should
    /// say "tap to stop" instead of "release to stop".
    private(set) var isHandsFree = false {
        didSet { if !isHandsFree { handsFreeEndsAt = nil } }
    }
    /// When a locked session will end itself, so the HUD can count down.
    private(set) var handsFreeEndsAt: Date?

    let recovery: TranscriptRecovery

    private let settings: SettingsStore
    private let permissions: PermissionCenter
    private let secureInput: SecureInputMonitor

    private let hotkey: any HotkeyMonitoring
    private let audio: any AudioCapturing
    private let speech: any SpeechEngine
    private let processor: any TextProcessing
    private let inserter: any TextInserting

    /// Single-flight lock. Not derived from `state` so it cannot be
    /// accidentally cleared by a state transition.
    private var isSessionInFlight = false

    /// Provisional capture is running but no session has begun. Separate from
    /// `isSessionInFlight` because an accidental tap opens the microphone
    /// without ever opening a session.
    private var isPreRolling = false

    /// A pre-roll that failed to start. Reported at `begin` rather than on the
    /// physical press, so a stray tap never shows the user an error.
    private var preRollFailure: String?

    /// The in-flight `beginSession`. Awaited at release so a slow analyzer
    /// start cannot race the finalise, and cancelled on Escape.
    private var recognitionStart: Task<Void, any Error>?

    /// The processor's trace for the dictation just processed, for the
    /// diagnostic log. Supplied by the composition root.
    var latestTrace: (@MainActor () -> ProductionTextProcessor.Trace?)?

    init(settings: SettingsStore,
         permissions: PermissionCenter,
         secureInput: SecureInputMonitor,
         recovery: TranscriptRecovery,
         hotkey: any HotkeyMonitoring,
         audio: any AudioCapturing,
         speech: any SpeechEngine,
         processor: any TextProcessing,
         inserter: any TextInserting) {
        self.settings = settings
        self.permissions = permissions
        self.secureInput = secureInput
        self.recovery = recovery
        self.hotkey = hotkey
        self.audio = audio
        self.speech = speech
        self.processor = processor
        self.inserter = inserter
    }

    // MARK: - Lifecycle

    func start() {
        hotkey.onTriggerPressed = { [weak self] in self?.handleTriggerPressed() }
        hotkey.onPress = { [weak self] in self?.handlePress() }
        hotkey.onRelease = { [weak self] in self?.handleRelease() }
        hotkey.onCancel = { [weak self] in self?.handleCancel() }
        hotkey.onHandsFreeLocked = { [weak self] in self?.handleHandsFreeLocked() }
        hotkey.update(binding: settings.preferences.hotkey,
                      triggerMode: settings.preferences.triggerMode,
                      handsFree: settings.preferences.handsFreeDoubleTap)

        do {
            try hotkey.start()
        } catch {
            Log.hotkey.error("hotkey start failed: \(error.localizedDescription, privacy: .public)")
        }
        reevaluateReadiness()
    }

    func stop() {
        hotkey.stop()
    }

    /// Called when a preference changes, so the hotkey rebinds without a restart.
    func applyPreferences() {
        hotkey.update(binding: settings.preferences.hotkey,
                      triggerMode: settings.preferences.triggerMode,
                      handsFree: settings.preferences.handsFreeDoubleTap)
    }

    /// Recompute whether dictation is currently possible. Driven by the
    /// permission and secure-input pollers.
    func reevaluateReadiness() {
        guard !state.isBusy else { return }

        if secureInput.isActive {
            transition(to: .blocked(.secureInput(holder: secureInput.holderDescription)))
            return
        }
        let missing = permissions.missing
        if !missing.isEmpty {
            transition(to: .blocked(.missingPermissions(missing)))
            return
        }
        if case .blocked = state {
            transition(to: .idle)
        }
    }

    // MARK: - Gesture handling

    /// Physical trigger down — ~151 ms before `begin` (ADR-018).
    ///
    /// Starts provisional capture so the user can speak immediately. Nothing
    /// user-visible happens here: the state stays `idle` until the gesture
    /// proves itself, so an accidental tap never flickers the menu-bar icon.
    private func handleTriggerPressed() {
        guard state.canStartSession, !isSessionInFlight, !isPreRolling else { return }
        // Readiness is checked *before* opening the microphone, not after.
        if secureInput.isActive || !permissions.missing.isEmpty {
            reevaluateReadiness()
            return
        }
        do {
            try audio.beginPreRoll()
            isPreRolling = true
        } catch {
            // Surfaced now rather than swallowed: a microphone that cannot open
            // should say so on the first press, not on release.
            preRollFailure = error.localizedDescription
            Log.audio.error("pre-roll failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Hold threshold reached. The provisional capture becomes a real session.
    private func handlePress() {
        guard state.canStartSession, !isSessionInFlight else {
            Log.session.info("press ignored — state \(String(describing: self.state), privacy: .public)")
            return
        }
        if let failure = preRollFailure {
            preRollFailure = nil
            isPreRolling = false
            finish(with: .audioUnavailable(failure))
            return
        }
        guard isPreRolling else {
            // begin without a live pre-roll means capture never started.
            finish(with: .audioUnavailable("Audio capture did not start."))
            return
        }
        if secureInput.isActive || !permissions.missing.isEmpty {
            audio.cancel()
            isPreRolling = false
            reevaluateReadiness()
            return
        }

        isSessionInFlight = true
        let session = DictationSession(locale: settings.preferences.locale.rawValue,
                                       processingMode: settings.preferences.processingMode.rawValue)
        currentSession = session

        // Promotion returns the live audio feed, pre-roll first. Recognition
        // starts now and runs while the user speaks, so release only finalises
        // (ADR-020).
        // Capture where the text is meant to go *now*, not at insertion time.
        // If the user switches apps while dictating, that must be detectable
        // rather than silently obeyed (ADR-023).
        (inserter as? InsertionChain)?.captureIntendedTarget()

        let feed = audio.promoteToSession()
        let locale = session.locale
        recognitionStart = Task { [speech] in
            try await speech.beginSession(locale: locale, audio: feed)
        }
        transition(to: .listening(startedAt: session.startedAt))
    }

    /// Only meaningful right after `handlePress` opened a session. If that press
    /// was ignored (a previous dictation still processing) there is no session
    /// to lock and the flag stays false.
    private func handleHandsFreeLocked() {
        guard case .listening = state else { return }
        isHandsFree = true
        handsFreeEndsAt = Date().addingTimeInterval(HandsFreeLimit.seconds)
    }

    private func handleRelease() {
        guard case .listening = state, var session = currentSession else {
            // A release with no session: the pre-roll never got promoted.
            discardPreRoll()
            return
        }
        isPreRolling = false
        isHandsFree = false
        session.releasedAt = Date()
        currentSession = session
        transition(to: .transcribing)
        Task { await runPipeline() }
    }

    /// One handler for both meanings of cancel: an accidental tap that never
    /// became a session, and Escape during a live one. The audio treatment is
    /// identical — discard — and only the session bookkeeping differs.
    private func handleCancel() {
        guard state.isBusy else {
            discardPreRoll()
            return
        }
        isPreRolling = false
        isHandsFree = false
        preRollFailure = nil
        audio.cancel()
        // Audio and recognition are cancelled together; a surviving analyzer
        // would finalise a transcript nobody asked for and could leak it into
        // the next session.
        let pending = recognitionStart
        recognitionStart = nil
        Task { [speech] in
            pending?.cancel()
            await speech.cancelSession()
        }
        Log.session.info("session cancelled by user")
        finish(with: nil)
    }

    private func discardPreRoll() {
        preRollFailure = nil
        guard isPreRolling else { return }
        isPreRolling = false
        audio.cancel()
    }

    /// The microphone vanished or the route changed mid-capture. ADR-015: the
    /// coordinator must never be left stuck in `listening`.
    func handleCaptureInterrupted(_ reason: String) {
        isPreRolling = false
        preRollFailure = nil
        let pending = recognitionStart
        recognitionStart = nil
        Task { [speech] in
            pending?.cancel()
            await speech.cancelSession()
        }
        guard state.isBusy else { return }
        finish(with: .audioUnavailable(reason))
    }

    // MARK: - Pipeline

    /// Phases 5–7 fill the services in. The ordering and the invariants are
    /// fixed here now so they cannot drift later.
    private func runPipeline() async {
        guard var session = currentSession else { return }
        let locale = session.locale

        let clip: AudioClip
        do {
            let start = Date()
            clip = try await audio.finishRecording()
            session.audioFinalizeMilliseconds = Date().timeIntervalSince(start) * 1000
            // Off unless --debug-audio-export. See DebugAudioExport.
            DebugAudioExport.write(clip)
            Log.audio.info("clip \(AVAudioEngineCapture.round2(clip.duration), privacy: .public) s, \(clip.frameCount, privacy: .public) frames, pre-roll \(AVAudioEngineCapture.round2(clip.preRollDuration * 1000), privacy: .public) ms, finalize \(AVAudioEngineCapture.round2(session.finalizeMilliseconds ?? 0), privacy: .public) ms")
        } catch {
            finish(with: .audioUnavailable(error.localizedDescription))
            return
        }

        let transcript: EngineTranscript
        do {
            // The analyzer has been consuming since `begin`; this only waits for
            // its start to have completed and then drains the tail.
            try await recognitionStart?.value
            recognitionStart = nil
            let start = Date()
            transcript = try await speech.finishSession()
            session.finalizeMilliseconds = Date().timeIntervalSince(start) * 1000
            Log.speech.info("key-up → transcript \(AVAudioEngineCapture.round2(session.finalizeMilliseconds ?? 0), privacy: .public) ms for \(AVAudioEngineCapture.round2(clip.duration), privacy: .public) s of audio")
        } catch SpeechEngineError.noSpeechDetected {
            finish(with: .noSpeechDetected)
            return
        } catch {
            finish(with: .transcriptionFailed(error.localizedDescription))
            return
        }

        guard !transcript.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            finish(with: .noSpeechDetected)
            return
        }

        transition(to: .processing)
        let processingStart = Date()
        let smart = settings.preferences.processingMode == .smart
        let finalText = await processor.process(transcript, smart: smart)
        session.processingMilliseconds = Date().timeIntervalSince(processingStart) * 1000

        // ADR-015: record BEFORE insertion. Everything after this point can
        // fail without the user losing their words.
        let transcriptID = recovery.record(text: finalText, locale: locale)
        session.transcriptID = transcriptID
        session.targetBundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        currentSession = session

        transition(to: .inserting)
        let insertionStart = Date()
        let outcome = await inserter.insert(finalText)
        session.insertionMilliseconds = Date().timeIntervalSince(insertionStart) * 1000
        currentSession = session

        // One line per dictation with the whole breakdown, so a slow run can be
        // attributed without instrumenting again. Counts and milliseconds only
        // — never the text.
        let keyUpToVisible = session.releasedAt.map { Date().timeIntervalSince($0) * 1000 } ?? 0
        let r = AVAudioEngineCapture.round2
        Log.session.info("end-to-end \(r(keyUpToVisible), privacy: .public) ms = transcript \(r(session.finalizeMilliseconds ?? 0), privacy: .public) + process \(r(session.processingMilliseconds ?? 0), privacy: .public) + insert \(r(session.insertionMilliseconds ?? 0), privacy: .public) — \(finalText.count, privacy: .public) chars, \(smart ? "smart" : "fast", privacy: .public)")

        if settings.preferences.recordDiagnosticTranscripts || DiagnosticTranscriptLog.launchFlag {
            let delivery: String = switch outcome {
            case .inserted(let strategy): "inserted via \(strategy)"
            case .refused(let reason): "REFUSED: \(reason)"
            case .failed(let reason): "FAILED: \(reason)"
            }
            DiagnosticTranscriptLog.record(
                trace: latestTrace?(),
                final: finalText,
                locale: locale,
                audioSeconds: clip.duration,
                finalizeMs: session.finalizeMilliseconds ?? 0,
                delivery: delivery,
                target: (inserter as? InsertionChain)?.diagnostics.lastTargetDescription)
        }

        switch outcome {
        case .inserted(let strategy):
            recovery.markOutcome(transcriptID, .inserted)
            Log.session.info("inserted via \(strategy, privacy: .public) in \(Int(session.insertionMilliseconds ?? 0), privacy: .public) ms")
            finish(with: nil)
        case .refused(let reason):
            recovery.markOutcome(transcriptID, .blocked, detail: reason)
            finish(with: .insertionFailed(reason))
        case .failed(let reason):
            recovery.markOutcome(transcriptID, .insertionFailed, detail: reason)
            finish(with: .insertionFailed(reason))
        }
    }

    // MARK: - Transitions

    private func finish(with failure: FailureReason?) {
        isSessionInFlight = false
        isHandsFree = false
        currentSession = nil
        if let failure {
            Log.session.error("session failed: \(failure.title, privacy: .public) — \(failure.detail, privacy: .public)")
            transition(to: .failed(failure))
        } else {
            transition(to: .idle)
            reevaluateReadiness()
        }
    }

    private func transition(to next: SessionState) {
        guard next != state else { return }
        Log.session.info("\(String(describing: self.state), privacy: .public) -> \(String(describing: next), privacy: .public)")
        state = next
    }

    // MARK: - Debug hooks

    /// Drive the state machine directly. Used by the debug menu to verify every
    /// menu-bar state renders (Phase 3 acceptance criterion 1) without needing
    /// the audio and speech services to exist.
    func debugForceState(_ next: SessionState) {
        transition(to: next)
    }

    /// Change the dictation language without going through the settings window.
    func debugSetLocale(_ locale: Preferences.DictationLocale) {
        settings.preferences.locale = locale
    }

    func debugRecordTranscript(_ text: String) {
        let id = recovery.record(text: text, locale: settings.preferences.locale.rawValue)
        recovery.markOutcome(id, .insertionFailed, detail: "Debug entry")
    }
}
