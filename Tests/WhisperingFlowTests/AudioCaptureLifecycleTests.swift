import Foundation
import HotkeyGestureCore
import Testing
@testable import WhisperingFlowKit

// MARK: - Fakes

/// Records the exact order of lifecycle calls, which is what Phase 5 is about.
@MainActor
final class FakeAudioCapture: AudioCapturing {
    enum Call: Equatable { case prepare, beginPreRoll, promote, finish, cancel }

    var calls: [Call] = []
    var isEngineRunning = false
    var isCapturing = false

    var preRollError: (any Error)?
    var finishError: (any Error)?
    var clip = AudioClip(samples: [0.1, 0.2, 0.3], sampleRate: 16_000, preRollFrameCount: 1)

    func prepare() throws { calls.append(.prepare) }

    func beginPreRoll() throws {
        calls.append(.beginPreRoll)
        if let preRollError { throw preRollError }
        isCapturing = true
        isEngineRunning = true
    }

    /// Feed handed to the recogniser. Retained so tests can push samples into a
    /// live session the way the real capture does.
    var feed: AsyncStream<[Float]>.Continuation?

    @discardableResult
    func promoteToSession() -> AsyncStream<[Float]> {
        calls.append(.promote)
        let (stream, continuation) = AsyncStream<[Float]>.makeStream()
        feed = continuation
        return stream
    }

    func finishRecording() async throws -> AudioClip {
        calls.append(.finish)
        feed?.finish(); feed = nil
        isCapturing = false
        isEngineRunning = false
        if let finishError { throw finishError }
        return clip
    }

    func cancel() {
        calls.append(.cancel)
        feed?.finish(); feed = nil
        isCapturing = false
        isEngineRunning = false
    }

    func consumePeakLevel() -> Float { 0 }
}

@MainActor
final class FakeHotkeyMonitor: HotkeyMonitoring {
    var onTriggerPressed: (() -> Void)?
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onCancel: (() -> Void)?
    var onHandsFreeLocked: (() -> Void)?
    var isRunning = false
    var hasReceivedAnyEvent = false

    func start() throws { isRunning = true }
    func stop() { isRunning = false }
    func update(binding: HotkeyBinding, triggerMode: TriggerMode, handsFree: Bool) {}

    /// Physical press → hold threshold → release, the normal path.
    func fullHold() {
        onTriggerPressed?()
        onPress?()
        onRelease?()
    }

    /// Press and release inside the hold threshold.
    func accidentalTap() {
        onTriggerPressed?()
        onCancel?()
    }

    /// Press, hold past the threshold, then Escape.
    func holdThenEscape() {
        onTriggerPressed?()
        onPress?()
        onCancel?()
    }
}

/// Records what was handed to insertion, so recovery and no-auto-Return can be
/// asserted without driving a real app.
@MainActor
final class FakeInserter: TextInserting {
    var inserted: [String] = []
    var outcome: InsertionOutcome = .inserted(strategy: "fake")

    func insert(_ text: String) async -> InsertionOutcome {
        inserted.append(text)
        return outcome
    }
}

@MainActor
func makeCoordinator(
    audio: FakeAudioCapture,
    hotkey: FakeHotkeyMonitor,
    speech: FakeSpeechEngine = FakeSpeechEngine(),
    processor: any TextProcessing = PassthroughTextProcessor(),
    inserter: FakeInserter = FakeInserter()
) -> DictationCoordinator {
    let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
    let granted = Dictionary(uniqueKeysWithValues: Permission.allCases.map { ($0, PermissionStatus.granted) })
    return DictationCoordinator(
        settings: SettingsStore(defaults: defaults),
        permissions: PermissionCenter(statuses: granted),
        secureInput: SecureInputMonitor(),
        recovery: TranscriptRecovery(),
        hotkey: hotkey,
        audio: audio,
        speech: speech,
        processor: processor,
        inserter: inserter)
}

// MARK: - Lifecycle

@Suite("Pre-roll capture lifecycle (ADR-018)")
@MainActor
struct PreRollLifecycleTests {

    @Test("Capture starts on the physical press, ~151 ms before begin")
    func captureStartsAtTriggerPressed() {
        let audio = FakeAudioCapture()
        let hotkey = FakeHotkeyMonitor()
        let coordinator = makeCoordinator(audio: audio, hotkey: hotkey)
        coordinator.start()

        hotkey.onTriggerPressed?()
        #expect(audio.calls.contains(.beginPreRoll),
                "waiting for begin would lose the first syllable of every utterance")
        #expect(audio.isCapturing)
        // Nothing user-visible yet: an accidental tap must not flicker the icon.
        #expect(coordinator.state == .idle)
    }

    @Test("The hands-free flag follows the session and clears when it ends")
    func handsFreeFlagFollowsTheSession() async {
        let audio = FakeAudioCapture()
        let hotkey = FakeHotkeyMonitor()
        let coordinator = makeCoordinator(audio: audio, hotkey: hotkey)
        coordinator.start()

        hotkey.onTriggerPressed?()
        hotkey.onPress?()
        hotkey.onHandsFreeLocked?()
        #expect(coordinator.isHandsFree)

        hotkey.onCancel?()
        #expect(!coordinator.isHandsFree, "a finished session must not stay marked hands-free")
    }

    @Test("A lock signal with no session (press ignored) does not mark hands-free")
    func handsFreeLockWithoutSessionIsIgnored() async {
        let hotkey = FakeHotkeyMonitor()
        let coordinator = makeCoordinator(audio: FakeAudioCapture(), hotkey: hotkey)
        coordinator.start()
        hotkey.onHandsFreeLocked?()
        #expect(!coordinator.isHandsFree)
    }

    @Test("The full hold promotes exactly once, in order")
    func fullHoldOrder() async {
        let audio = FakeAudioCapture()
        let hotkey = FakeHotkeyMonitor()
        let coordinator = makeCoordinator(audio: audio, hotkey: hotkey)
        coordinator.start()

        hotkey.onTriggerPressed?()
        hotkey.onPress?()
        #expect(audio.calls.filter { $0 == .promote }.count == 1)
        if case .listening = coordinator.state {} else {
            Issue.record("expected listening, got \(coordinator.state)")
        }

        hotkey.onRelease?()
        await Task.yield()
        #expect(audio.calls.filter { $0 == .finish }.count == 1)
        #expect(audio.calls.firstIndex(of: .beginPreRoll)! < audio.calls.firstIndex(of: .promote)!)
        #expect(audio.calls.firstIndex(of: .promote)! < audio.calls.firstIndex(of: .finish)!)
    }

    @Test("An accidental tap discards its audio and opens no session")
    func accidentalTapDiscards() {
        let audio = FakeAudioCapture()
        let hotkey = FakeHotkeyMonitor()
        let coordinator = makeCoordinator(audio: audio, hotkey: hotkey)
        coordinator.start()

        hotkey.accidentalTap()
        #expect(audio.calls == [.beginPreRoll, .cancel],
                "a stray ⌘ press must not leave recorded audio in memory")
        #expect(!audio.calls.contains(.promote))
        #expect(!audio.calls.contains(.finish))
        #expect(coordinator.state == .idle)
        #expect(!audio.isCapturing)
    }

    @Test("Escape during a session discards the audio and transcribes nothing")
    func escapeDiscards() {
        let audio = FakeAudioCapture()
        let hotkey = FakeHotkeyMonitor()
        let coordinator = makeCoordinator(audio: audio, hotkey: hotkey)
        coordinator.start()

        hotkey.holdThenEscape()
        #expect(audio.calls == [.beginPreRoll, .promote, .cancel])
        #expect(!audio.calls.contains(.finish), "cancelled audio must never reach the engine")
        #expect(coordinator.state == .idle)
    }

    @Test("A new dictation works immediately after a cancellation")
    func newSessionAfterCancel() async {
        let audio = FakeAudioCapture()
        let hotkey = FakeHotkeyMonitor()
        let coordinator = makeCoordinator(audio: audio, hotkey: hotkey)
        coordinator.start()

        hotkey.holdThenEscape()
        audio.calls.removeAll()

        hotkey.onTriggerPressed?()
        hotkey.onPress?()
        hotkey.onRelease?()
        await Task.yield()
        #expect(audio.calls == [.beginPreRoll, .promote, .finish])
    }

    @Test("Repeated accidental taps never accumulate a second capture")
    func repeatedTapsAreIdempotent() {
        let audio = FakeAudioCapture()
        let hotkey = FakeHotkeyMonitor()
        let coordinator = makeCoordinator(audio: audio, hotkey: hotkey)
        coordinator.start()

        for _ in 0..<5 { hotkey.accidentalTap() }
        #expect(audio.calls.filter { $0 == .beginPreRoll }.count == 5)
        #expect(audio.calls.filter { $0 == .cancel }.count == 5)
        #expect(!audio.isCapturing)
    }

    @Test("A second trigger press while already pre-rolling does not restart capture")
    func duplicateTriggerIsIgnored() {
        let audio = FakeAudioCapture()
        let hotkey = FakeHotkeyMonitor()
        let coordinator = makeCoordinator(audio: audio, hotkey: hotkey)
        coordinator.start()

        hotkey.onTriggerPressed?()
        hotkey.onTriggerPressed?()
        #expect(audio.calls.filter { $0 == .beginPreRoll }.count == 1,
                "restarting would throw away the pre-roll captured so far")
    }
}

// MARK: - Failure paths (ADR-015)

@Suite("Audio failures never wedge the coordinator")
@MainActor
struct AudioFailureTests {

    @Test("A microphone that cannot start reports at begin and returns to a usable state")
    func preRollFailureSurfacesAtBegin() {
        let audio = FakeAudioCapture()
        audio.preRollError = AudioCaptureError.noInputDevice
        let hotkey = FakeHotkeyMonitor()
        let coordinator = makeCoordinator(audio: audio, hotkey: hotkey)
        coordinator.start()

        hotkey.onTriggerPressed?()
        // No error yet — a failed pre-roll on a stray tap must stay silent.
        #expect(coordinator.state == .idle)

        hotkey.onPress?()
        if case .failed(let reason) = coordinator.state {
            #expect(reason.detail.contains("microphone") || reason.detail.contains("No microphone"))
        } else {
            Issue.record("expected failed, got \(coordinator.state)")
        }
        #expect(coordinator.state.canStartSession, "a failure must not block the next attempt")
    }

    @Test("A capture interruption mid-session cannot leave the app listening")
    func interruptionUnsticksTheCoordinator() {
        let audio = FakeAudioCapture()
        let hotkey = FakeHotkeyMonitor()
        let coordinator = makeCoordinator(audio: audio, hotkey: hotkey)
        coordinator.start()

        hotkey.onTriggerPressed?()
        hotkey.onPress?()
        if case .listening = coordinator.state {} else { Issue.record("expected listening") }

        // The USB microphone was unplugged.
        coordinator.handleCaptureInterrupted("The microphone was disconnected.")
        #expect(coordinator.state.canStartSession)
        if case .failed = coordinator.state {} else {
            Issue.record("expected a visible failure, got \(coordinator.state)")
        }
    }

    @Test("An interruption while merely pre-rolling is silent and recoverable")
    func interruptionWhilePreRollingIsSilent() async {
        let audio = FakeAudioCapture()
        let hotkey = FakeHotkeyMonitor()
        let coordinator = makeCoordinator(audio: audio, hotkey: hotkey)
        coordinator.start()

        hotkey.onTriggerPressed?()
        coordinator.handleCaptureInterrupted("The microphone was disconnected.")
        #expect(coordinator.state == .idle)

        audio.calls.removeAll()
        hotkey.onTriggerPressed?()
        hotkey.onPress?()
        hotkey.onRelease?()
        await Task.yield()
        #expect(audio.calls == [.beginPreRoll, .promote, .finish])
    }

    @Test("A finish that throws still returns the app to a usable state")
    func finishFailureRecovers() async {
        let audio = FakeAudioCapture()
        audio.finishError = AudioCaptureError.noAudioCaptured
        let hotkey = FakeHotkeyMonitor()
        let coordinator = makeCoordinator(audio: audio, hotkey: hotkey)
        coordinator.start()

        hotkey.fullHold()
        await Task.yield()
        #expect(coordinator.state.canStartSession)
        #expect(!coordinator.state.isBusy)
    }

    @Test("A release with no session discards the pre-roll rather than stranding it")
    func strayReleaseDiscards() {
        let audio = FakeAudioCapture()
        let hotkey = FakeHotkeyMonitor()
        let coordinator = makeCoordinator(audio: audio, hotkey: hotkey)
        coordinator.start()

        hotkey.onTriggerPressed?()
        hotkey.onRelease?()          // begin never arrived
        #expect(audio.calls == [.beginPreRoll, .cancel])
        #expect(!audio.isCapturing, "a running microphone with no session is the worst outcome")
    }
}

// MARK: - Clip shape

@Suite("AudioClip is engine-ready")
@MainActor
struct AudioClipTests {

    @Test("Duration and frame count derive from the samples, not from a stored field")
    func derivedProperties() {
        let clip = AudioClip(samples: [Float](repeating: 0, count: 24_000),
                             sampleRate: 16_000,
                             preRollFrameCount: 2_400)
        #expect(clip.frameCount == 24_000)
        #expect(clip.duration == 1.5)
        #expect(clip.preRollDuration == 0.15, "the pre-roll must cover the 150 ms hold threshold")
    }

    @Test("The canonical format is 16 kHz mono Float32")
    func canonicalFormat() {
        // Both target engines are served by this: SpeechTranscriber requantises
        // to Int16 at the same rate, Parakeet takes Float32 as-is. Neither
        // needs a resample.
        #expect(AVAudioEngineCapture.targetFormat.sampleRate == 16_000)
        #expect(AVAudioEngineCapture.targetFormat.channelCount == 1)
        #expect(AVAudioEngineCapture.targetFormat.commonFormat == .pcmFormatFloat32)
    }
}
