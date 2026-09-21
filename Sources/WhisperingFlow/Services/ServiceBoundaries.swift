import Foundation
import HotkeyGestureCore

/// The seams later phases fill in.
///
/// They exist now, unimplemented, so the coordinator's shape is fixed before
/// the hard parts arrive — and so Phase 3 can be tested end-to-end with fakes.
/// Each maps to a phase in IMPLEMENTATION_PLAN.md.

// MARK: - Phase 4: global shortcut

@MainActor
protocol HotkeyMonitoring: AnyObject {
    /// Physical trigger down, ahead of the hold threshold. Exists so audio
    /// capture can pre-roll; it is provisional and always resolved by either
    /// `onPress` (promoted) or `onCancel` (discarded). See ADR-018.
    var onTriggerPressed: (() -> Void)? { get set }
    var onPress: (() -> Void)? { get set }
    var onRelease: (() -> Void)? { get set }
    var onCancel: (() -> Void)? { get set }
    /// A double-tap locked the session open (fired right after `onPress`).
    var onHandsFreeLocked: (() -> Void)? { get set }

    /// True only if the tap installed. Says nothing about whether events are
    /// arriving — that distinction cost a debugging session in Phase 2
    /// (TECH_RESEARCH §15.7) and is why `hasReceivedAnyEvent` exists.
    var isRunning: Bool { get }
    var hasReceivedAnyEvent: Bool { get }

    func start() throws
    func stop()
    func update(binding: HotkeyBinding, triggerMode: TriggerMode, handsFree: Bool)
}

// MARK: - Phase 5: audio capture

@MainActor
protocol AudioCapturing: AnyObject {
    var isEngineRunning: Bool { get }
    var isCapturing: Bool { get }

    func prepare() throws

    /// Physical trigger down. Starts provisional capture into a bounded
    /// pre-roll buffer — `begin` is ~151 ms later and capture that waits for it
    /// loses the first syllable (ADR-018).
    func beginPreRoll() throws

    /// Hold threshold reached: the provisional audio is now a real dictation.
    ///
    /// Returns a stream of 16 kHz mono Float32 in capture order, starting with
    /// the spliced pre-roll. The recogniser consumes this *while the user is
    /// still speaking*, so release only has to finalise (ADR-020). The stream
    /// finishes when the capture does.
    @discardableResult
    func promoteToSession() -> AsyncStream<[Float]>

    func finishRecording() async throws -> AudioClip

    /// Accidental tap, Escape, or failure. Stops capture and drops the audio.
    func cancel()

    /// Peak magnitude since the last read, for the future waveform HUD.
    func consumePeakLevel() -> Float
}

/// Canonical speech audio: mono, normalised to −1…1.
///
/// Float32 at 16 kHz is the common denominator. Apple's `SpeechTranscriber`
/// wants Int16 at 16 kHz (TECH_RESEARCH §15, discovered the hard way when every
/// spike WAV came out 0.0 s) and Parakeet/FluidAudio wants Float32 at 16 kHz.
/// Keeping Float32 internally means Phase 6 converts once, and the conversion to
/// Int16 is a same-rate requantisation rather than a resample.
struct AudioClip: Sendable, Equatable {
    let samples: [Float]
    let sampleRate: Double
    /// Leading frames that came from the pre-roll buffer. Diagnostic only — the
    /// samples are already spliced in.
    let preRollFrameCount: Int

    var frameCount: Int { samples.count }
    var duration: TimeInterval { Double(samples.count) / sampleRate }
    var preRollDuration: TimeInterval { Double(preRollFrameCount) / sampleRate }
}

// MARK: - Phase 6: speech recognition
//
// `SpeechEngine` lives in Speech/SpeechEngine.swift — the lifecycle is
// streaming, not a single `transcribe(clip)` call (ADR-020).

/// Named `EngineTranscript`, not `RawTranscript`, deliberately.
///
/// Phase 2.5 established the text is **not** raw: the engine has already applied
/// its own capitalisation, punctuation and number formatting, inconsistently
/// (QUALITY_BENCHMARK §15.11). Calling it "raw" misled the pipeline design once
/// already.
struct EngineTranscript: Sendable, Equatable {
    let text: String
    let locale: String
    let detectedLocale: String?
    let confidence: Double?
}

// MARK: - Phase 7/8: text processing and insertion

protocol TextProcessing: Sendable {
    func process(_ transcript: EngineTranscript, smart: Bool) async -> String
}

@MainActor
protocol TextInserting: AnyObject {
    func insert(_ text: String) async -> InsertionOutcome
}

enum InsertionOutcome: Equatable, Sendable {
    case inserted(strategy: String)
    case refused(reason: String)
    case failed(reason: String)

    var succeeded: Bool {
        if case .inserted = self { return true }
        return false
    }
}
