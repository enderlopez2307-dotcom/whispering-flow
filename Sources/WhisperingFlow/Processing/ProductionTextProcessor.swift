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
        let locale: ProcessingContext.DictationLocale =
            transcript.locale.hasPrefix("es") ? .spanish : .english
        let rules = await vocabularyProvider()

        // 1. Vocabulary, measured separately because it is the stage that has to
        //    be right for technical speech to be usable at all.
        let vocabularyStart = Date()
        let vocabulary = VocabularyStage.replace(in: transcript.text, using: rules)
        let vocabularyMs = Date().timeIntervalSince(vocabularyStart) * 1000

        // 2. Deterministic cleanup. The vocabulary stage is in the pipeline too, so
        //    it gets an empty table here: it has already run, and it is NOT
        //    idempotent — a second pass let `claude → Claude` rewrite the
        //    "CLAUDE.md" that `claude md → CLAUDE.md` had just produced.
        let context = ProcessingContext(locale: locale, vocabulary: [])
        let deterministicStart = Date()
        let deterministic = pipeline.process(vocabulary.text, context: context)
        let deterministicMs = Date().timeIntervalSince(deterministicStart) * 1000

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
