import Foundation

/// Recognition, and nothing else.
///
/// **The engine owns recognition only.** No vocabulary replacement, no
/// deterministic cleanup, no LLM. Those are `TextProcessing`'s job and run
/// downstream — Phase 2.5 established that vocabulary-before-cleanup wins every
/// divergence (QUALITY_BENCHMARK), and that ordering is only enforceable if the
/// engine never touches the text.
///
/// The lifecycle is **streaming**, not batch. Apple's analyzer consumes audio
/// while the user is still speaking, so key-up only has to finalise: the Phase 2
/// spike measured 76–151 ms that way (TECH_RESEARCH §15). A `transcribe(clip)`
/// shape would throw that away by starting from scratch at release. See ADR-020.
///
/// ```
/// prepare(locale:)                     once, at launch — installs/reserves assets
/// beginSession(locale:audio:)          at semantic `begin` — analyzer starts consuming
/// finishSession() -> EngineTranscript  at `end` — finalise only
/// cancelSession()                      at `cancel` — tear down, no transcript
/// ```
protocol SpeechEngine: Sendable {

    /// Install and reserve what the locale needs. Safe to call repeatedly.
    func prepare(locale: String) async throws

    /// Start consuming. `audio` yields 16 kHz mono Float32 in −1…1, in capture
    /// order, and is finished by the caller at release.
    func beginSession(locale: String, audio: AsyncStream<[Float]>) async throws

    /// Drain the remaining audio and return what the recogniser produced.
    func finishSession() async throws -> EngineTranscript

    /// Abandon the session. No transcript, and nothing may survive into the next.
    func cancelSession() async

    /// Whether a session is currently open. Part of the single-flight proof.
    var hasActiveSession: Bool { get async }
}

extension SpeechEngine {
    /// Batch convenience, expressed in terms of the streaming API so there is
    /// exactly one transcription path. Used by the corpus harness and tests —
    /// never by the live pipeline, which streams.
    func transcribe(_ clip: AudioClip, locale: String) async throws -> EngineTranscript {
        let (stream, continuation) = AsyncStream<[Float]>.makeStream()
        try await beginSession(locale: locale, audio: stream)
        // Fed in capture-sized chunks rather than one block, so the corpus
        // exercises the same code path as a live dictation.
        var index = 0
        let chunk = 1_600            // 100 ms at 16 kHz
        while index < clip.samples.count {
            let end = min(index + chunk, clip.samples.count)
            continuation.yield(Array(clip.samples[index..<end]))
            index = end
        }
        continuation.finish()
        return try await finishSession()
    }
}

/// Where a locale's assets stand. Surfaced so the UI can explain a wait rather
/// than appearing to hang.
enum EngineReadiness: Equatable, Sendable {
    case unknown
    case unsupportedLocale(String)
    case notInstalled
    case installing(Double)
    case ready

    var isReady: Bool { self == .ready }

    var description: String {
        switch self {
        case .unknown: "Checking language support…"
        case .unsupportedLocale(let locale): "\(locale) is not supported by the speech engine."
        case .notInstalled: "The language model is not installed yet."
        case .installing(let fraction): "Downloading the language model… \(Int(fraction * 100))%"
        case .ready: "Ready."
        }
    }
}

enum SpeechEngineError: LocalizedError, Equatable {
    case unsupportedLocale(String)
    case assetInstallationFailed(locale: String, detail: String)
    case analyzerUnavailable(String)
    case sessionAlreadyActive
    case noSessionActive
    case noSpeechDetected

    var errorDescription: String? {
        switch self {
        case .unsupportedLocale(let locale):
            "\(locale) is not available for on-device dictation on this Mac."
        case .assetInstallationFailed(let locale, let detail):
            "The \(locale) language model could not be installed: \(detail)"
        case .analyzerUnavailable(let detail):
            "The speech recogniser could not start: \(detail)"
        case .sessionAlreadyActive:
            "A transcription is already running."
        case .noSessionActive:
            "No transcription was running."
        case .noSpeechDetected:
            "No speech was detected."
        }
    }
}
