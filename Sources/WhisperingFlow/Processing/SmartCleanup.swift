import Foundation
import FoundationModels
import TextProcessingCore

/// Optional Apple on-device polish, run **after** vocabulary and deterministic
/// cleanup.
///
/// Deliberately narrow, and the narrowness is the finding: Phase 2.5 measured
/// that the model cannot be trusted to recover technical vocabulary — it left
/// `ductation` alone and rendered `glock code` as `Glock Code`. It also invents
/// plausible-but-wrong language often enough that this is **not** "more
/// accurate" than Fast mode, only more aggressively polished. Fast is the safer
/// default (ADR-022).
///
/// Every failure path returns the deterministic text unchanged. There is no
/// route through this type that loses the transcript.
struct SmartCleanup: Sendable {

    struct Outcome: Sendable, Equatable {
        var text: String
        var milliseconds: Double
        /// True when the deterministic input was returned instead of a model
        /// result, for any reason.
        var fellBack: Bool
        var reason: String?

        static func fallback(_ text: String, _ reason: String, _ ms: Double) -> Outcome {
            Outcome(text: text, milliseconds: ms, fellBack: true, reason: reason)
        }
    }

    /// `.default` guardrails refuse this task outright: the model reads a
    /// dictated transcript as a request addressed to it rather than as content.
    /// `.permissiveContentTransformations` is what makes transformation legal,
    /// and it was necessary, not convenient (TECH_RESEARCH §16).
    private static let model = SystemLanguageModel(
        useCase: .general, guardrails: .permissiveContentTransformations)

    static var isAvailable: Bool { model.isAvailable }
    static var availabilityDescription: String { "\(model.availability)" }

    /// English instructions. Tuned: a longer, more explicit variant measured
    /// **worse** in the §16 comparison, so this is an artifact of measurement
    /// rather than a draft to improve.
    static let instructionsEN = """
        You clean up raw speech-to-text transcripts of dictated text.

        Rules, in priority order:
        1. Never add information, opinions, or sentences that were not spoken.
        2. Fix obvious speech-recognition errors using context — for example a \
        word that is phonetically close to the correct one but makes no sense.
        3. Remove filler words and false starts. When the speaker corrects \
        themselves mid-sentence, keep only the corrected version.
        4. Fix grammar only where the recognizer clearly garbled it. Keep the \
        speaker's own wording and register otherwise. Do not make it more formal.
        5. Spelling of names is already correct — never change a capitalised \
        product or company name.
        6. NEVER TRANSLATE. Output must be in exactly the same language as the \
        input. A Spanish transcript stays Spanish; an English transcript stays \
        English. Translating is the worst possible failure.
        7. Output only the cleaned text. No preamble, no explanation, no quotes.
        """

    /// Spanish instructions, written **in Spanish**.
    ///
    /// An English instruction block containing "NEVER TRANSLATE" did not stop
    /// the model translating Spanish transcripts into English (benchmark #13,
    /// #14). Addressing it in the target language is the fix that actually
    /// held: hard failures went from 3/18 to 1/18.
    static let instructionsES = """
        Limpias transcripciones de dictado por voz en español.

        Reglas, por orden de prioridad:
        1. Nunca añadas información, opiniones ni frases que no se dijeron.
        2. Corrige errores evidentes de reconocimiento de voz usando el contexto.
        3. Elimina muletillas y frases abandonadas. Si la persona se corrige a \
        mitad de frase, conserva solo la versión corregida.
        4. Corrige la gramática solo donde el reconocedor la haya estropeado. \
        Mantén las palabras y el registro de la persona. No lo hagas más formal.
        5. Los nombres propios ya están bien escritos: nunca cambies un nombre \
        de producto o empresa que esté en mayúscula.
        6. RESPONDE SIEMPRE EN ESPAÑOL. Nunca traduzcas al inglés.
        7. Devuelve solo el texto corregido, sin explicaciones ni comillas.
        """

    /// Budget for one run, scaled to the input.
    ///
    /// A flat 4 s budget was wrong for real use. Field measurement: 1282
    /// characters took **3989 ms**, 11 ms inside the old limit, and anything
    /// longer silently timed out and inserted the Fast text instead. Measured
    /// cost is ~2.7–3.1 ms per character (740 chars → 2004 ms, 1282 → 3989 ms),
    /// so the budget allows twice that plus a fixed allowance for session
    /// start, never less than the old 4 s, and never more than 15 s — past
    /// that the wait itself is the failure.
    static func timeout(forCharacters count: Int) -> Duration {
        let seconds = min(15, max(4, 2 + Double(count) * 0.006))
        return .milliseconds(Int(seconds * 1000))
    }

    /// Clean `text`, or return it unchanged. Never throws.
    static func clean(_ text: String, locale: ProcessingContext.DictationLocale) async -> Outcome {
        let start = Date()
        func elapsed() -> Double { Date().timeIntervalSince(start) * 1000 }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .fallback(text, "empty input", 0) }
        guard model.isAvailable else {
            return .fallback(text, "Apple Intelligence is not available", elapsed())
        }

        let spanish = locale == .spanish
        // Delimited so the transcript reads as data to transform, never as an
        // instruction addressed to the model.
        let prompt = spanish ? """
            Corrige la transcripción entre los marcadores. Responde en español. \
            Devuelve solo el texto corregido.

            <<<TRANSCRIPCION
            \(text)
            TRANSCRIPCION>>>
            """ : """
            Clean up the transcript between the markers, keeping it in its \
            original language. Output only the cleaned text.

            <<<TRANSCRIPT
            \(text)
            TRANSCRIPT>>>
            """

        let session = LanguageModelSession(model: model,
                                           instructions: spanish ? instructionsES : instructionsEN)
        let options = GenerationOptions(temperature: 0.1)
        let budget = timeout(forCharacters: text.count)

        do {
            let raw = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    try await session.respond(to: prompt, options: options).content
                }
                group.addTask {
                    try await Task.sleep(for: budget)
                    throw SmartCleanupError.timedOut
                }
                guard let first = try await group.next() else { throw SmartCleanupError.timedOut }
                group.cancelAll()
                return first
            }

            let candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if looksLikeRefusal(candidate) {
                return .fallback(text, "model refused", elapsed())
            }
            let verdict = sanitize(candidate, against: text)
            guard case .accepted(let cleaned) = verdict else {
                if case .rejected(let why) = verdict { return .fallback(text, why, elapsed()) }
                return .fallback(text, "rejected", elapsed())
            }
            return Outcome(text: cleaned, milliseconds: elapsed(), fellBack: false, reason: nil)
        } catch is SmartCleanupError {
            return .fallback(text, "timed out after \(String(format: "%.1f", elapsed() / 1000)) s", elapsed())
        } catch {
            return .fallback(text, error.localizedDescription, elapsed())
        }
    }

    enum Verdict: Equatable {
        case accepted(String)
        case rejected(String)
    }

    /// Strip conversational packaging, then sanity-check what is left.
    ///
    /// The model intermittently ignores "output only the cleaned text" and
    /// replies like a chat assistant — `Sure, here is the cleaned-up
    /// transcript:` followed by a fenced code block. Pasting *that* into the
    /// user's document is far worse than leaving a recognition error in, so
    /// anything still structurally wrong after unwrapping is discarded.
    ///
    /// Only visible under repeated-run testing; a single run looks fine.
    static func sanitize(_ raw: String, against input: String) -> Verdict {
        var text = raw

        // 1. Prefer the contents of a fenced block.
        if let open = text.range(of: "```") {
            var inner = String(text[open.upperBound...])
            if let close = inner.range(of: "```") { inner = String(inner[..<close.lowerBound]) }
            var lines = inner.split(separator: "\n", omittingEmptySubsequences: false)
            // Drop a language tag ("swift", "text", …).
            if let first = lines.first {
                let tag = first.trimmingCharacters(in: .whitespaces)
                if !tag.isEmpty, tag.range(of: "^[a-zA-Z]{1,12}$", options: .regularExpression) != nil {
                    lines.removeFirst()
                }
            }
            text = lines.joined(separator: "\n")
        }

        // 2. Drop a short leading preamble line ending in a colon.
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > 1, let first = lines.first {
            let candidate = first.trimmingCharacters(in: .whitespaces)
            if candidate.hasSuffix(":"), candidate.count < 80 {
                text = lines.dropFirst().joined(separator: "\n")
            }
        }

        // 3. Strip wrapping quotes.
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > 1, text.hasPrefix("\""), text.hasSuffix("\"") {
            text = String(text.dropFirst().dropLast())
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // 4. Semantic safety. A cleanup pass never empties the text, never
        //    leaves fences behind, and never changes its length dramatically —
        //    a large swing means it summarised or expanded, both of which lose
        //    or invent content.
        if text.isEmpty { return .rejected("model returned nothing") }
        if text.contains("```") { return .rejected("model returned a code fence") }

        let ratio = input.isEmpty ? 1 : Double(text.count) / Double(input.count)
        if ratio > 1.6 { return .rejected("model expanded the text (\(String(format: "%.2f", ratio))×)") }
        if ratio < 0.4 { return .rejected("model dropped content (\(String(format: "%.2f", ratio))×)") }
        return .accepted(text)
    }

    /// Phrases specific enough not to fire on a transcript that merely *starts*
    /// like one. A bare `i cannot` prefix matched "I cannot wait to deploy
    /// this" — a perfectly good cleanup that would have been thrown away.
    static let refusalOpenings = [
        "i'm sorry", "i am sorry", "sorry, i can",
        "i cannot help", "i cannot assist", "i cannot provide", "i cannot comply",
        "i can't help", "i can't assist", "i can't provide", "i can't comply",
        "as an ai", "lo siento", "no puedo ayudar", "no puedo procesar",
        "no puedo asistir", "no puedo completar",
    ]

    static func looksLikeRefusal(_ text: String) -> Bool {
        let lowered = text.lowercased()
        if refusalOpenings.contains(where: { lowered.hasPrefix($0) }) { return true }
        return lowered.contains("cannot assist with this request")
    }

    /// One throwaway call so live latencies are steady-state rather than
    /// including first-call model load.
    static func warmUp() async {
        guard isAvailable else { return }
        _ = await clean("This is a warm up sentence.", locale: .english)
    }
}

private enum SmartCleanupError: Error { case timedOut }
