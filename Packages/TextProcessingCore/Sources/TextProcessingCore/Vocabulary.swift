import Foundation

/// One personal-dictionary rule.
///
/// Identity is a stable `id` rather than the spoken form, so editing a rule in
/// settings does not silently create a second one.
public struct VocabularyRule: Sendable, Equatable, Codable, Identifiable {
    public var id: UUID
    /// What the recogniser produced.
    public var spoken: String
    /// What should be written instead, emitted with exactly this casing.
    public var replacement: String
    public var isEnabled: Bool
    /// Shipped with the app. Still editable and deletable — it is the user's
    /// dictionary, not ours — but marked so the seed can be re-offered.
    public var isBuiltIn: Bool
    /// Why this rule exists. Shown in settings so a surprising correction can be
    /// understood rather than just deleted.
    public var note: String?

    public init(id: UUID = UUID(),
                spoken: String,
                replacement: String,
                isEnabled: Bool = true,
                isBuiltIn: Bool = false,
                note: String? = nil) {
        self.id = id
        self.spoken = spoken
        self.replacement = replacement
        self.isEnabled = isEnabled
        self.isBuiltIn = isBuiltIn
        self.note = note
    }

    /// Catches empty rules and exact no-ops typed by accident.
    ///
    /// The comparison is **case-sensitive on purpose**. Half the shipped
    /// dictionary is casing-only — `supabase → Supabase` — and that is its
    /// entire job. An earlier case-insensitive check classified every one of
    /// those as a no-op and silently dropped them, which the tests caught.
    public var isUseful: Bool {
        let spokenTrimmed = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacementTrimmed = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        return !spokenTrimmed.isEmpty
            && !replacementTrimmed.isEmpty
            && spokenTrimmed != replacementTrimmed
    }
}

/// Deterministic phrase replacement over a transcript.
///
/// Runs **before** any cleanup and before Smart mode. Phase 2.5 measured that
/// vocabulary-before-LLM beat LLM-on-raw in every divergence, and that the LLM
/// cannot be trusted to recover technical terms at all — it left `ductation`
/// alone and turned `glock code` into `Glock Code` (QUALITY_BENCHMARK).
public struct VocabularyStage: TextStage {
    public let id = StageID("vocabulary")

    public init() {}

    public func apply(_ input: String, context: ProcessingContext) -> String {
        Self.replace(in: input, using: context.vocabulary).text
    }

    public struct Result: Sendable, Equatable {
        public var text: String
        /// Which rules fired, for diagnostics. Rule descriptions, never the
        /// surrounding transcript.
        public var hits: [String]
    }

    /// Longest spoken form first, so `claude code` wins over `claude` and the
    /// shorter rule never gets to split a phrase the longer one owns.
    ///
    /// Boundaries are explicit Unicode lookarounds rather than `\b`: Spanish
    /// technical speech puts English product names next to accented words, and
    /// `\b` semantics around non-ASCII letters are not worth betting on.
    ///
    /// Every rule matches against the *original* text and claims its span, so a
    /// later rule can never rewrite what an earlier one just produced: with
    /// `claude md → CLAUDE.md` and `claude → Claude`, rescanning the output turned
    /// "CLAUDE.md" into "Claude.md" (the "." is a word boundary).
    public static func replace(in input: String, using rules: [VocabularyRule]) -> Result {
        let source = input as NSString
        let full = NSRange(location: 0, length: source.length)
        var edits: [(range: NSRange, replacement: String)] = []
        var hits: [String] = []

        let active = rules
            .filter { $0.isEnabled && $0.isUseful }
            .sorted { $0.spoken.count > $1.spoken.count }

        for rule in active {
            guard let regex = cache.regex(for: rule.spoken) else { continue }
            var changedSomething = false
            for match in regex.matches(in: input, range: full) {
                if edits.contains(where: { NSIntersectionRange($0.range, match.range).length > 0 }) {
                    continue
                }
                edits.append((match.range, rule.replacement))
                if source.substring(with: match.range) != rule.replacement { changedSomething = true }
            }
            if changedSomething { hits.append("\(rule.spoken) → \(rule.replacement)") }
        }
        guard !edits.isEmpty else { return Result(text: input, hits: hits) }

        // Back to front, so earlier ranges stay valid while later ones are replaced.
        let output = NSMutableString(string: input)
        for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
            output.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        return Result(text: output as String, hits: hits)
    }

    /// Compile every rule's pattern ahead of the first dictation.
    ///
    /// Compiling costs roughly a quarter of a millisecond per rule, so a
    /// thousand-rule starter dictionary would otherwise add a few hundred
    /// milliseconds to the *first* dictation after launch. Call this once at
    /// startup, off the main thread; rules added later compile lazily, one at a
    /// time, which is invisible.
    public static func warmUp(_ rules: [VocabularyRule]) {
        for rule in rules where rule.isEnabled && rule.isUseful { _ = cache.regex(for: rule.spoken) }
    }

    /// Compiled patterns, keyed by spoken form.
    ///
    /// Recompiling all 48 rules on every dictation measured 13–24 ms — a fifth
    /// of the entire Fast-mode budget, spent re-deriving something that never
    /// changes. Bounded by the size of the dictionary.
    static let cache = PatternCache()

    final class PatternCache: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: NSRegularExpression] = [:]

        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return storage.count
        }

        func regex(for spoken: String) -> NSRegularExpression? {
            lock.lock(); defer { lock.unlock() }
            if let cached = storage[spoken] { return cached }
            let escaped = NSRegularExpression.escapedPattern(for: spoken)
            // Not `\b`: that would let "supabase" fire inside "supabases".
            let pattern = "(?<![\\p{L}\\p{N}])\(escaped)(?![\\p{L}\\p{N}])"
            guard let regex = try? NSRegularExpression(pattern: pattern,
                                                       options: [.caseInsensitive])
            else { return nil }
            storage[spoken] = regex
            return regex
        }
    }
}

/// The shipped seed.
///
/// **Every entry is either an error actually observed in testing, or a
/// casing-only rule that cannot change meaning.** Speculative variants are
/// deliberately absent: a dictionary that invents corrections corrupts
/// legitimate speech, and the cost of a missed term (retype one word) is far
/// lower than the cost of a wrong replacement (a sentence that says something
/// the user did not say).
///
/// Rejected on purpose: `b code → VS Code` (would fire on "B code"),
/// `claw → Claude` (fires on the animal), and any single common word.
public enum DefaultVocabulary {

    /// Hand-observed rules first, then the generated starter pack, then the
    /// author's own field rules (`PersonalSeed`, empty in the public copy). The
    /// first rule for a spoken form wins, so a hand-checked rule is never
    /// overridden by a generated one.
    public static func seed() -> [VocabularyRule] {
        let observedRules = (observed + StarterVocabulary.observed + PersonalSeed.observed)
            .map { VocabularyRule(spoken: $0.0, replacement: $0.1, isBuiltIn: true, note: $0.2) }
        let casingRules = (casingOnly + StarterVocabulary.casingOnly + PersonalSeed.casingOnly)
            .map {
                VocabularyRule(spoken: $0.0, replacement: $0.1, isBuiltIn: true,
                               note: "Canonical spelling — cannot change meaning.")
            }
        var seen = Set<String>()
        return (observedRules + casingRules).filter { seen.insert($0.spoken.lowercased()).inserted }
    }

    /// (spoken, replacement, why). Observed in the Phase 2.5/2.6 corpus, the
    /// long-form dictation test, or Phase 6 live testing.
    static let observed: [(String, String, String)] = [
        ("clock code",   "Claude Code", "Benchmark #7, en_US."),
        ("glock code",   "Claude Code", "Long-form dictation test, 2026-08-22."),
        ("cloud code",   "Claude Code", "Phase 6 live test and 106 s long-form."),
        ("claw code",    "Claude Code", "106 s long-form dictation."),
        ("clod code",    "Claude Code", "Phonetically adjacent to the observed set."),
        ("cloud flare",  "Cloudflare",  "Phase 6 live test: 'uncheck cloud flare'."),
        ("cloud flair",  "Cloudflare",  "106 s long-form dictation."),
        ("cloudflur",    "Cloudflare",  "Synthetic-speech bench."),
        ("superbase",    "Supabase",    "Phase 6 live test and synthetic bench."),
        ("supa base",    "Supabase",    "Phonetic split of the observed error."),
        ("super base",   "Supabase",    "Phonetic split of the observed error."),
        ("su pae",       "Supabase",    "Benchmark #19, es_ES. 'pae' is not a Spanish word, so this cannot fire on a real 'su …' phrase."),
        ("whisper flow", "Wispr Flow",  "Long-form dictation test."),
        ("ductation",    "dictation",   "Long-form dictation test."),
        ("versal",       "Vercel",      "Synthetic-speech bench."),
        ("sedance",      "Seedance",    "Synthetic-speech bench."),
        ("seedons",      "Seedance",    "Synthetic-speech bench."),
        ("seedans",      "Seedance",    "Synthetic-speech bench."),
        ("duchboard",    "dashboard",   "Phase 6 live test, es_ES."),
        ("duchboards",   "dashboards",  "Phase 6 live test, es_ES."),
        ("duchashboard", "dashboard",   "Phase 6 live test, es_ES."),
        // --- observed 2026-08-24, milestone live test in TextEdit ---
        ("supervise edge",  "Supabase edge", "Milestone live test: 'Deploy the supervise edge function'. Scoped to 'edge' so it cannot fire on the ordinary verb."),
        ("we clock out",    "Claude Code",   "Milestone live test: 'we clock out' for 'with Claude Code'."),
        ("clock out and",   "Claude Code and", "Same utterance, alternate split."),
        ("cloud out",       "Claude Code",   "Phonetically adjacent to the observed 'clock out'."),
        // --- observed 2026-08-24, milestone live test, es_ES ---
        // Spanish speakers hit English product names differently: the engine
        // splits and re-spells them rather than mangling them wholesale.
        ("su pabase",       "Supabase",    "Milestone live test, es_ES."),
        ("supage",          "Supabase",    "Milestone live test, es_ES."),
        ("supabas",         "Supabase",    "Phonetically adjacent to the observed set."),
        ("clo code",        "Claude Code", "Milestone live test, es_ES."),
        ("clau code",       "Claude Code", "Phonetically adjacent to the observed 'Clo Code'."),
        ("clauud",          "Cloudflare",  "Milestone live test, es_ES: 'Cloudflare' inside Spanish."),
        ("cloudflar",       "Cloudflare",  "Phonetically adjacent to the observed set."),
        ("corsar",          "cursor",      "Milestone live test, en_US: 'wherever my cursor happens to be'."),
        ("course or",       "cursor",      "Milestone live test, en_US, second run."),
        ("su papage",       "Supabase",    "Milestone live test, es_ES, second run."),
        ("supaves",         "Supabase",    "Milestone live test, es_ES."),
        ("super bes",       "Supabase",    "Milestone live test, es_ES."),
        ("clocode",         "Claude Code", "Milestone live test, es_ES, second run — no space."),
        ("cloud co",        "Claude Code", "Milestone live test, es_ES."),
        ("claude flair",    "Cloudflare",  "Milestone live test, es_ES: the engine hears the Claude prefix then Cloudflare's tail."),
        ("claude flare",    "Cloudflare",  "Phonetically adjacent to the observed 'Claude Flair'."),
        // --- observed Aug–Sept 2026, three weeks of daily use (field log) ---
        // Only spoken forms that are not ordinary words. Mappings whose spoken
        // form IS a real word (soneto, cortex, claw, clots) belong in the user's
        // own dictionary, where they can be switched off, not in the seed.
        ("ai slope",            "AI slop",             "Field log 10 Sept."),
        ("speech reconnection", "speech recognition",  "Field log: repeatable, several times in one message."),
        ("voice reconnection",  "voice recognition",   "Same mishearing, scoped to its only plausible context."),
    ]

    /// Casing and spacing only. The words are already recognised correctly;
    /// these just write them the way the product is actually spelled.
    static let casingOnly: [(String, String)] = [
        ("claude code",      "Claude Code"),
        ("chat gpt",         "ChatGPT"),
        ("chatgpt",          "ChatGPT"),
        ("open ai",          "OpenAI"),
        ("openai",           "OpenAI"),
        ("anthropic",        "Anthropic"),
        ("supabase",         "Supabase"),
        ("cloudflare",       "Cloudflare"),
        ("vercel",           "Vercel"),
        ("seedance",         "Seedance"),
        ("higgsfield",       "Higgsfield"),
        ("vs code",          "VS Code"),
        ("v s code",         "VS Code"),
        ("swift ui",         "SwiftUI"),
        ("swiftui",          "SwiftUI"),
        ("core ml",          "CoreML"),
        ("coreml",           "CoreML"),
        ("wispr flow",       "Wispr Flow"),
        ("whispering flow",  "Whispering Flow"),
        ("github",           "GitHub"),
        ("git hub",          "GitHub"),
        ("javascript",       "JavaScript"),
        ("typescript",       "TypeScript"),
        ("postgres",         "Postgres"),
        ("xcode",            "Xcode"),
        ("macos",            "macOS"),
        ("ios",              "iOS"),
        ("payhip",           "Payhip"),
        ("pay hip",          "Payhip"),
        ("squarespace",      "Squarespace"),
        ("square space",     "Squarespace"),
    ]
}
