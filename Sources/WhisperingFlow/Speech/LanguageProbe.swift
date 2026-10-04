import AudioCaptureCore
import Foundation
import NaturalLanguage
import TextProcessingCore

/// Measurement harness for automatic English/Spanish: runs the production
/// automatic session over each clip and prints what each recogniser heard and
/// what the merge chose. Headless and read-only (`--probe-languages <dir>`).
enum LanguageProbe {

    static func probeDirectory(_ directory: URL) async {
        let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "wav" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let engine = AppleSpeechEngine()
        for locale in ["en_US", "es_ES"] { try? await engine.prepare(locale: locale) }
        for file in files {
            guard let clip = try? CorpusValidation.readClip(at: file) else { continue }
            do {
                // PROBE_REALTIME feeds audio at speaking pace, so finalize time
                // means what it means live; PROBE_LOCALE compares one language.
                let environment = ProcessInfo.processInfo.environment
                let locale = environment["PROBE_LOCALE"] ?? AppleSpeechEngine.automaticLocale
                let audio = environment["PROBE_REALTIME"] != nil ? realtimeStream(of: clip) : stream(of: clip)
                try await engine.beginSession(locale: locale, audio: audio)
                // Live, finishSession is called at key-up, after the speech.
                if environment["PROBE_REALTIME"] != nil { try await Task.sleep(for: .seconds(clip.duration + 0.2)) }
                let transcript = try await engine.finishSession()
                let object: [String: Any] = [
                    "file": file.lastPathComponent,
                    "english": transcript.bilingual?.englishText ?? "",
                    "spanish": transcript.bilingual?.spanishText ?? "",
                    "merged": transcript.text,
                    "language": transcript.detectedLocale ?? "mixed",
                    "finalizeMs": await engine.diagnostics.finalizeMilliseconds,
                ]
                if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                   let line = String(data: data, encoding: .utf8) {
                    print(line)
                }
            } catch {
                print("{\"file\":\"\(file.lastPathComponent)\",\"error\":\"\(error.localizedDescription)\"}")
            }
        }
    }

    static func realtimeStream(of clip: AudioClip) -> AsyncStream<[Float]> {
        let (stream, continuation) = AsyncStream<[Float]>.makeStream()
        let samples = clip.samples
        Task {
            var index = 0
            while index < samples.count {
                let end = min(index + 1_600, samples.count)
                continuation.yield(Array(samples[index..<end]))
                index = end
                try? await Task.sleep(for: .milliseconds(100))
            }
            continuation.finish()
        }
        return stream
    }

    static func stream(of clip: AudioClip) -> AsyncStream<[Float]> {
        let (stream, continuation) = AsyncStream<[Float]>.makeStream()
        var index = 0
        while index < clip.samples.count {
            let end = min(index + 1_600, clip.samples.count)
            continuation.yield(Array(clip.samples[index..<end]))
            index = end
        }
        continuation.finish()
        return stream
    }
}

/// `NLLanguageRecognizer`, constrained to the two languages the app dictates.
enum LanguageLikelihood {
    static func spanish(_ text: String) -> Double {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.english, .spanish]
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 2)
        let spanish = hypotheses[.spanish] ?? 0
        let english = hypotheses[.english] ?? 0
        return spanish + english > 0 ? spanish / (spanish + english) : 0
    }
}
