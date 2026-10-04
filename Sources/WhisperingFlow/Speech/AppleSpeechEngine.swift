import AVFoundation
import AudioCaptureCore
import Foundation
import Speech
import TextProcessingCore

/// Apple `SpeechAnalyzer` + `SpeechTranscriber`, on device.
///
/// An `actor`, but the single-flight guarantee does **not** rest on that: actors
/// are reentrant across `await`, so a second `beginSession` can enter while the
/// first is suspended inside asset installation. `activeSession` is an explicit
/// gate, checked and set without an intervening suspension, and it is
/// unit-tested (ARCHITECTURE §3.1, ADR-020).
actor AppleSpeechEngine: SpeechEngine {

    /// Everything belonging to one dictation. Held as a unit so `cancelSession`
    /// cannot leave half of it behind — the Phase 5 converter leak was exactly
    /// that class of bug.
    private struct Session {
        let locale: String
        let analyzer: SpeechAnalyzer
        /// One per language: a single transcriber normally, English and
        /// Spanish side by side in automatic mode.
        let transcribers: [SpeechTranscriber]
        let continuation: AsyncStream<AnalyzerInput>.Continuation
        let results: [Task<Heard, Never>]
        let feeder: Task<Void, Never>
        let startedAt: Date
    }

    /// What one transcriber produced. Words are only collected in automatic
    /// mode, where the merge needs their timing and confidence.
    struct Heard: Sendable {
        var text = ""
        var words: [TimedWord] = []
    }

    /// The `locale` that asks for automatic English/Spanish.
    static let automaticLocale = "auto"
    static let automaticPair = ["en-US", "es-ES"]

    private var activeSession: Session?
    private var readiness: [String: EngineReadiness] = [:]

    /// Analyzer input format, resolved once per locale. Apple returns **Int16**
    /// at 16 kHz here, not Float32 — reading only `floatChannelData` silently
    /// produced empty audio for a whole Phase 2.5 session (TECH_RESEARCH §15).
    private var analyzerFormats: [String: AVAudioFormat] = [:]

    private(set) var diagnostics = SpeechDiagnostics()

    var hasActiveSession: Bool { activeSession != nil }

    func readinessFor(_ locale: String) -> EngineReadiness { readiness[locale] ?? .unknown }

    // MARK: - Preparation

    /// Install and reserve a locale's assets. Idempotent and safe to call for
    /// both locales at launch — Phase 2.5 Q1 established that `en_US` and
    /// `es_ES` reserve simultaneously (max 5), so switching costs nothing later.
    func prepare(locale identifier: String) async throws {
        if identifier == Self.automaticLocale {
            for locale in Self.automaticPair { try await prepare(locale: locale) }
            return
        }
        if readiness[identifier]?.isReady == true { return }

        let locale = Locale(identifier: identifier.replacingOccurrences(of: "_", with: "-"))
        let supported = await SpeechTranscriber.supportedLocales
        guard supported.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) else {
            readiness[identifier] = .unsupportedLocale(identifier)
            throw SpeechEngineError.unsupportedLocale(identifier)
        }

        let started = Date()
        let module = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                readiness[identifier] = .installing(0)
                Log.speech.info("installing \(identifier, privacy: .public) speech assets…")
                try await request.downloadAndInstall()
            }
            _ = try await AssetInventory.reserve(locale: locale)
        } catch {
            readiness[identifier] = .notInstalled
            throw SpeechEngineError.assetInstallationFailed(
                locale: identifier, detail: error.localizedDescription)
        }

        if analyzerFormats[identifier] == nil {
            analyzerFormats[identifier] =
                await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
        }
        readiness[identifier] = .ready
        diagnostics.prepareMilliseconds = Date().timeIntervalSince(started) * 1000
        diagnostics.analyzerFormat = analyzerFormats[identifier].map(Self.describe) ?? "—"
        Log.speech.info("\(identifier, privacy: .public) ready in \(Self.round2(self.diagnostics.prepareMilliseconds), privacy: .public) ms — analyzer format \(self.diagnostics.analyzerFormat, privacy: .public)")
    }

    // MARK: - Session

    func beginSession(locale identifier: String, audio: AsyncStream<[Float]>) async throws {
        // Explicit, and before any `await`: two sessions sharing one analyzer
        // would interleave results silently.
        guard activeSession == nil else { throw SpeechEngineError.sessionAlreadyActive }

        let started = Date()
        try await prepare(locale: identifier)

        // `prepare` suspends, so re-check. Without this the guard above is
        // decorative — this is the actor-reentrancy hole ARCHITECTURE §3.1 warns
        // about, and it is the reason the flag exists at all.
        guard activeSession == nil else { throw SpeechEngineError.sessionAlreadyActive }

        let automatic = identifier == Self.automaticLocale
        let transcribers: [SpeechTranscriber]
        if automatic {
            // Time ranges and confidence per word are what the merge decides on.
            // Requested only here, so single-language dictation is unchanged.
            let preset = SpeechTranscriber.Preset.progressiveTranscription
            transcribers = Self.automaticPair.map {
                SpeechTranscriber(locale: Locale(identifier: $0),
                                  transcriptionOptions: preset.transcriptionOptions,
                                  reportingOptions: preset.reportingOptions,
                                  attributeOptions: [.audioTimeRange, .transcriptionConfidence])
            }
        } else {
            let locale = Locale(identifier: identifier.replacingOccurrences(of: "_", with: "-"))
            transcribers = [SpeechTranscriber(locale: locale, preset: .progressiveTranscription)]
        }
        var resolved = analyzerFormats[identifier]
        if resolved == nil {
            resolved = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: transcribers)
        }
        guard let format = resolved else {
            throw SpeechEngineError.analyzerUnavailable("no compatible audio format for \(identifier)")
        }
        analyzerFormats[identifier] = format

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        // One analyzer for both languages in automatic mode: both hear the
        // same buffers, so their word timings share one clock.
        let analyzer = SpeechAnalyzer(modules: transcribers)

        // Results are consumed concurrently with capture. This is what makes
        // key-up cheap: by release, everything but the tail is already done.
        let results = transcribers.map { transcriber in
            Task<Heard, Never> {
                var heard = Heard()
                do {
                    for try await result in transcriber.results where result.isFinal {
                        heard.text += String(result.text.characters)
                        if automatic { heard.words += Self.timedWords(in: result) }
                    }
                } catch {
                    Log.speech.error("results stream: \(error.localizedDescription, privacy: .public)")
                }
                return heard
            }
        }

        // Convert and forward off the audio thread. The capture side only ever
        // yields into an `AsyncStream`; requantisation happens here.
        let feeder = Task<Void, Never> {
            for await samples in audio {
                guard let buffer = Self.makeBuffer(samples, format: format) else { continue }
                continuation.yield(AnalyzerInput(buffer: buffer))
            }
            continuation.finish()
        }

        do {
            try await analyzer.start(inputSequence: stream)
        } catch {
            feeder.cancel()
            results.forEach { $0.cancel() }
            continuation.finish()
            throw SpeechEngineError.analyzerUnavailable(error.localizedDescription)
        }

        activeSession = Session(locale: identifier,
                                analyzer: analyzer,
                                transcribers: transcribers,
                                continuation: continuation,
                                results: results,
                                feeder: feeder,
                                startedAt: Date())
        diagnostics.sessionStartMilliseconds = Date().timeIntervalSince(started) * 1000
        diagnostics.sessionsStarted += 1
    }

    func finishSession() async throws -> EngineTranscript {
        guard let session = activeSession else { throw SpeechEngineError.noSessionActive }
        activeSession = nil
        let finalizeStart = Date()

        // The feeder finishes the analyzer's input stream once the audio stream
        // closes; waiting for it is what guarantees the last buffer is in.
        await session.feeder.value
        do {
            try await session.analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            Log.speech.error("finalize: \(error.localizedDescription, privacy: .public)")
        }
        var heard: [Heard] = []
        for task in session.results { heard.append(await task.value) }

        diagnostics.finalizeMilliseconds = Date().timeIntervalSince(finalizeStart) * 1000
        diagnostics.sessionsFinished += 1

        let transcript: EngineTranscript
        if session.locale == Self.automaticLocale, heard.count == 2 {
            transcript = Self.merge(english: heard[0], spanish: heard[1])
        } else {
            transcript = EngineTranscript(
                text: (heard.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                locale: session.locale, detectedLocale: nil, confidence: nil)
        }
        let language = transcript.bilingual.map { _ in transcript.detectedLocale ?? "mixed" } ?? session.locale
        Log.speech.info("finalized \(session.locale, privacy: .public) → \(language, privacy: .public) in \(Self.round2(self.diagnostics.finalizeMilliseconds), privacy: .public) ms, \(transcript.text.count, privacy: .public) chars")

        guard !transcript.text.isEmpty else { throw SpeechEngineError.noSpeechDetected }
        return transcript
    }

    // MARK: - Automatic English/Spanish

    static func merge(english: Heard, spanish: Heard) -> EngineTranscript {
        let englishText = english.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let spanishText = spanish.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = BilingualMerge.merge(english: english.words, spanish: spanish.words,
                                          englishText: englishText, spanishText: spanishText,
                                          spanishLikelihood: LanguageLikelihood.spanish)
        let detected: String? = switch result.language {
        case .english: automaticPair[0]
        case .spanish: automaticPair[1]
        case nil: nil
        }
        return EngineTranscript(text: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
                                locale: automaticLocale,
                                detectedLocale: detected,
                                confidence: nil,
                                bilingual: BilingualDetail(englishText: englishText,
                                                           spanishText: spanishText,
                                                           runs: result.runs))
    }

    /// One `TimedWord` per attributed run. The last word of a result is marked:
    /// the recogniser closed the result there because it heard a pause.
    static func timedWords(in result: SpeechTranscriber.Result) -> [TimedWord] {
        var words: [TimedWord] = []
        for run in result.text.runs {
            let text = String(result.text[run.range].characters)
            guard let range = run.audioTimeRange,
                  !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            words.append(TimedWord(text: text,
                                   start: range.start.seconds,
                                   end: range.end.seconds,
                                   confidence: run.transcriptionConfidence ?? 0))
        }
        if !words.isEmpty { words[words.count - 1].endsSegment = true }
        return words
    }

    func cancelSession() async {
        guard let session = activeSession else { return }
        activeSession = nil
        session.feeder.cancel()
        session.continuation.finish()
        session.results.forEach { $0.cancel() }
        // Finalising a cancelled session would produce a transcript nobody
        // asked for; the analyzer is dropped without it.
        await session.analyzer.cancelAndFinishNow()
        diagnostics.sessionsCancelled += 1
        Log.speech.info("session cancelled — no transcript produced")
    }

    // MARK: - Conversion

    /// Float32 −1…1 → the analyzer's format, same sample rate.
    ///
    /// Int16 is the format Apple actually asks for here, and it is a pure
    /// requantisation (`PCMConversion`, unit-tested for clipping, silence and
    /// quiet speech). Float32 is a straight copy. Anything else is refused
    /// loudly rather than resampled silently — `AudioClip` is already 16 kHz
    /// mono and a resample here would be a bug, not a feature.
    nonisolated static func makeBuffer(_ samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)

        switch format.commonFormat {
        case .pcmFormatInt16:
            guard let destination = buffer.int16ChannelData?[0] else { return nil }
            let converted = PCMConversion.int16(from: samples)
            converted.withUnsafeBufferPointer { destination.update(from: $0.baseAddress!, count: converted.count) }
        case .pcmFormatFloat32:
            guard let destination = buffer.floatChannelData?[0] else { return nil }
            samples.withUnsafeBufferPointer { destination.update(from: $0.baseAddress!, count: samples.count) }
        default:
            Log.speech.error("unexpected analyzer format \(format.commonFormat.rawValue, privacy: .public) — audio not delivered")
            return nil
        }
        return buffer
    }

    nonisolated static func describe(_ format: AVAudioFormat) -> String {
        let name = switch format.commonFormat {
        case .pcmFormatFloat32: "f32"
        case .pcmFormatInt16: "i16"
        case .pcmFormatInt32: "i32"
        default: "other"
        }
        return "\(Int(format.sampleRate)) Hz \(format.channelCount) ch \(name)"
    }

    nonisolated static func round2(_ value: Double) -> Double { (value * 100).rounded() / 100 }
}

/// Timings and counts. Never transcript text.
struct SpeechDiagnostics: Sendable, Equatable {
    var analyzerFormat = "—"
    var prepareMilliseconds: Double = 0
    var sessionStartMilliseconds: Double = 0
    var finalizeMilliseconds: Double = 0
    var sessionsStarted = 0
    var sessionsFinished = 0
    var sessionsCancelled = 0

    var summary: String {
        "analyzer \(analyzerFormat) | prepare \(AppleSpeechEngine.round2(prepareMilliseconds))ms"
        + " start \(AppleSpeechEngine.round2(sessionStartMilliseconds))ms"
        + " finalize \(AppleSpeechEngine.round2(finalizeMilliseconds))ms"
        + " (\(sessionsFinished)/\(sessionsStarted) done, \(sessionsCancelled) cancelled)"
    }
}
