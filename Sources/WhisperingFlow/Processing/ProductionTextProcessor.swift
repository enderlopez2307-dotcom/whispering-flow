import Foundation
import TextProcessingCore

/// The locked processing order (ADR-021):
///
/// ```
/// EngineTranscript → vocabulary → deterministic cleanup → [Smart] → FinalText
/// ```
///
/// Vocabulary runs **before** anything else, and before Smart mode in
/// particular. Phase 2.5 measured that vocabulary-before-LLM beat
/// LLM-on-raw-transcript in every single divergence, and that the model cannot
/// recover technical terms on its own. Reordering this needs new measurements,
/// not an opinion.
struct ProductionTextProcessor: TextProcessing {

    /// Every intermediate result, so Fast and Smart can be compared without
    /// running the dictation twice.
    struct Trace: Sendable, Equatable {
        var engine: String
        var afterVocabulary: String
        var deterministic: String
        var smart: String?
        var vocabularyHits: [String]
        var vocabularyMilliseconds: Double
        var deterministicMilliseconds: Double
        var smartMilliseconds: Double
        var smartFellBack: Bool
        var smartFallbackReason: String?
        /// Whether this run was in Smart mode at all. Without it a Fast run and
        /// a Smart run that produced nothing look identical.
        var smartRequested: Bool = false
        /// Filled in by the coordinator after delivery, for the diagnostic log.
        var insertion: String?
        /// Automatic mode: what each recogniser heard and which language won.
        var bilingual: BilingualDetail?
        var detectedLanguage: String?

        /// What actually gets inserted.
        var final: String { smart ?? deterministic }
    }

    private let pipeline: TextPipeline

    /// **`@MainActor`, and awaited — never `assumeIsolated`.**
    ///
    /// `process` is a non-isolated `async` protocol requirement, so it runs on
    /// the cooperative pool, not the main actor. An earlier version reached the
    /// vocabulary store with `MainActor.assumeIsolated` and took SIGTRAP on the
    /// very first real dictation — the same executor-assertion failure the
    /// Phase 2 audio tap hit (TECH_RESEARCH §15.4), in a new place.
    ///
    /// Declaring the isolation and awaiting it makes the hop explicit and the
    /// mistake impossible to repeat here.
    private let vocabularyProvider: @MainActor @Sendable () -> [VocabularyRule]
    /// Set by the coordinator so the menu and diagnostics can show the last run.
    let onTrace: @MainActor @Sendable (Trace) -> Void

    init(pipeline: TextPipeline = .production,
         vocabulary: @escaping @MainActor @Sendable () -> [VocabularyRule],
         onTrace: @escaping @MainActor @Sendable (Trace) -> Void = { _ in }) {
        self.pipeline = pipeline
        self.vocabularyProvider = vocabulary
        self.onTrace = onTrace
    }

    func process(_ transcript: EngineTranscript, smart: Bool) async -> String {
        // Automatic mode reports the language it heard; otherwise the setting.
        let language = transcript.detectedLocale ?? transcript.locale
        let locale: ProcessingContext.DictationLocale = language.hasPrefix("es") ? .spanish : .english
        let rules = await vocabularyProvider()
        // A mixed dictation is processed one language at a time: fillers,
        // stutters and question marks are per-language rules.
        let parts: [(text: String, locale: ProcessingContext.DictationLocale)] =
            if let runs = transcript.bilingual?.runs, runs.count > 1 {
                runs.map { ($0.text, $0.language == .spanish ? .spanish : .english) }
            } else {
                [(transcript.text, locale)]
            }

        // 1. Vocabulary, measured separately because it is the stage that has to
        //    be right for technical speech to be usable at all.
        let vocabularyStart = Date()
        let vocabularies = parts.map { VocabularyStage.replace(in: $0.text, using: rules) }
        let vocabularyMs = Date().timeIntervalSince(vocabularyStart) * 1000

        // 2. Deterministic cleanup. The vocabulary stage is in the pipeline too, so
        //    it gets an empty table here: it has already run, and it is NOT
        //    idempotent — a second pass let `claude → Claude` rewrite the
        //    "CLAUDE.md" that `claude md → CLAUDE.md` had just produced.
        let context = ProcessingContext(locale: locale, vocabulary: [])
        let deterministicStart = Date()
        var processed = zip(parts, vocabularies).map { part, vocabulary in
            pipeline.process(vocabulary.text, context: ProcessingContext(locale: part.locale, vocabulary: []))
        }
        // Each part is cleaned as if it opened a sentence, so a switch made
        // mid-sentence ("…I tried it, y luego…") came out "…I tried it, Y luego…".
        // After a comma, keep the recogniser's own lowercase start.
        for index in processed.indices.dropFirst() {
            let previous = processed[index - 1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let mark = previous.last, ",;:".contains(mark),
                  let raw = vocabularies[index].text.first(where: \.isLetter), raw.isLowercase,
                  let first = processed[index].firstIndex(where: \.isLetter)
            else { continue }
            processed[index].replaceSubrange(first...first, with: processed[index][first].lowercased())
        }
        // Each part got the trailing suffix; a mixed dictation gets it once.
        let deterministic = processed.count == 1 ? processed[0]
            : TrailingStage().apply(processed.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                                     .joined(separator: " "), context: context)
        let deterministicMs = Date().timeIntervalSince(deterministicStart) * 1000
        let vocabulary = (text: vocabularies.map(\.text).joined(separator: " "),
                          hits: vocabularies.flatMap(\.hits))

        var trace = Trace(engine: transcript.text,
                          afterVocabulary: vocabulary.text,
                          deterministic: deterministic,
                          smart: nil,
                          vocabularyHits: vocabulary.hits,
                          vocabularyMilliseconds: vocabularyMs,
                          deterministicMilliseconds: deterministicMs,
                          smartMilliseconds: 0,
                          smartFellBack: false,
                          smartFallbackReason: nil)

        trace.smartRequested = smart
        trace.bilingual = transcript.bilingual
        trace.detectedLanguage = transcript.bilingual == nil ? nil : (transcript.detectedLocale ?? "mixed")
        // Smart's prompts work in one language at a time (instruction language
        // must match content language, TECH_RESEARCH), so a mixed dictation
        // keeps its deterministic text rather than risk a half-translated one.
        if smart, parts.count > 1 {
            trace.smartFellBack = true
            trace.smartFallbackReason = "mixed English and Spanish"
            await onTrace(trace)
            return deterministic
        }
        guard smart else {
            await onTrace(trace)
            Log.processing.info("fast: vocab \(round2(vocabularyMs), privacy: .public) ms (\(vocabulary.hits.count, privacy: .public) hits), cleanup \(round2(deterministicMs), privacy: .public) ms")
            return deterministic
        }

        // 3. Smart mode. Its failure path returns the deterministic text, so
        //    there is no branch here that can lose the transcript.
        let outcome = await SmartCleanup.clean(deterministic, locale: locale)
        // Smart rewrites sentences and merges them, which dropped a "?" in the
        // field log. The question-mark stage is idempotent, so running it again
        // on the model's output costs nothing and restores the mark.
        let smartText = QuestionMarkStage().apply(outcome.text, context: context)
        trace.smartMilliseconds = outcome.milliseconds
        trace.smartFellBack = outcome.fellBack
        trace.smartFallbackReason = outcome.reason
        trace.smart = outcome.fellBack ? nil : smartText
        await onTrace(trace)

        if outcome.fellBack {
            Log.processing.info("smart fell back to deterministic: \(outcome.reason ?? "unknown", privacy: .public) (\(round2(outcome.milliseconds), privacy: .public) ms)")
        } else {
            Log.processing.info("smart: \(round2(outcome.milliseconds), privacy: .public) ms")
        }
        return smartText
    }

    private func round2(_ value: Double) -> Double { (value * 100).rounded() / 100 }
}
