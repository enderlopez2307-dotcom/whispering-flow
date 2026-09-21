import Foundation
import Testing
@testable import TextProcessingCore

private func rules(_ pairs: [(String, String)]) -> [VocabularyRule] {
    pairs.map { VocabularyRule(spoken: $0.0, replacement: $0.1) }
}

@Suite("Vocabulary matching is safe")
struct VocabularyMatchingTests {

    @Test("Longest phrase wins over a shorter overlapping one")
    func longestMatchFirst() {
        // "claude" alone would split the phrase and leave "Claude code".
        let table = rules([("claude", "Claude"), ("claude code", "Claude Code")])
        #expect(VocabularyStage.replace(in: "open claude code now", using: table).text
                == "open Claude Code now")
    }

    @Test("A shorter rule never rewrites what a longer rule just produced")
    func replacementIsNotRescanned() {
        // Field bug, 19 Sept 2026: `claude md → CLAUDE.md` fired, then the casing
        // rule `claude → Claude` matched the "CLAUDE" it had just written
        // (the "." is a word boundary) and the user got "Claude.md".
        let table = rules([("claude", "Claude"), ("claude md", "CLAUDE.md")])
        let result = VocabularyStage.replace(in: "read claude md and ask claude", using: table)
        #expect(result.text == "read CLAUDE.md and ask Claude")
        #expect(result.hits == ["claude md → CLAUDE.md", "claude → Claude"])
    }

    @Test("Replacements never fire inside a longer word")
    func noSubstringDamage() {
        let table = rules([("supabase", "Supabase"), ("er", "ERROR"), ("um", "UM")])
        // "supabases" must not become "Supabases"; "umbrella"/"number" must not
        // be touched by the filler-shaped rules.
        let input = "supabases umbrella number performer"
        #expect(VocabularyStage.replace(in: input, using: table).text == input)
    }

    @Test("Matching is case-insensitive but the replacement keeps its own casing")
    func casingIsFromTheRule() {
        let table = rules([("chatgpt", "ChatGPT")])
        #expect(VocabularyStage.replace(in: "CHATGPT and chatgpt and ChatGpt", using: table).text
                == "ChatGPT and ChatGPT and ChatGPT")
    }

    @Test("English product names survive inside Spanish speech")
    func spanishContextKeepsEnglishNames() {
        // The whole reason the boundary check uses Unicode classes: accented
        // words sit directly against English product names in real speech.
        let table = DefaultVocabulary.seed()
        let result = VocabularyStage.replace(
            in: "Quiero configurar superbase con cloud code y después revisar el duchboard",
            using: table)
        #expect(result.text == "Quiero configurar Supabase con Claude Code y después revisar el dashboard")
    }

    @Test("A rule adjacent to an accented word still matches")
    func accentAdjacency() {
        let table = rules([("supabase", "Supabase")])
        #expect(VocabularyStage.replace(in: "revisé supabase ayer", using: table).text
                == "revisé Supabase ayer")
    }

    @Test("Disabled rules do nothing")
    func disabledRulesAreInert() {
        let table = [VocabularyRule(spoken: "cloud code", replacement: "Claude Code", isEnabled: false)]
        #expect(VocabularyStage.replace(in: "open cloud code", using: table).text == "open cloud code")
    }

    @Test("A rule that replaces a word with itself is ignored")
    func selfReplacementIsIgnored() {
        #expect(!VocabularyRule(spoken: "Claude", replacement: "Claude").isUseful)
        // Casing-only rules ARE useful — that is most of the shipped dictionary.
        #expect(VocabularyRule(spoken: "supabase", replacement: "Supabase").isUseful)
        #expect(!VocabularyRule(spoken: "  ", replacement: "x").isUseful)
        #expect(!VocabularyRule(spoken: "x", replacement: "").isUseful)
        #expect(VocabularyRule(spoken: "cloud code", replacement: "Claude Code").isUseful)
    }

    @Test("Hits report which rules fired, not the surrounding text")
    func hitsAreRuleDescriptions() {
        let table = rules([("cloud code", "Claude Code"), ("superbase", "Supabase")])
        let result = VocabularyStage.replace(in: "cloud code and superbase", using: table)
        #expect(result.hits.count == 2)
        #expect(result.hits.allSatisfy { $0.contains("→") })
    }

    @Test("Replacement text is never re-interpreted as a pattern")
    func replacementIsLiteral() {
        // A `$1` in a replacement must land as characters, not a capture group.
        let table = rules([("dollar one", "$1"), ("backslash", "\\d")])
        #expect(VocabularyStage.replace(in: "dollar one and backslash", using: table).text
                == "$1 and \\d")
    }
}

@Suite("The shipped dictionary is conservative")
struct DefaultVocabularySafetyTests {

    @Test("Every seeded rule is useful and documented")
    func seedIsWellFormed() {
        for rule in DefaultVocabulary.seed() {
            #expect(rule.isUseful, "\(rule.spoken) → \(rule.replacement) is a no-op")
            #expect(rule.isBuiltIn)
            #expect(rule.note?.isEmpty == false, "\(rule.spoken) has no justification")
        }
    }

    @Test("No rule fires on a single common word")
    func noDangerousGenericRules() {
        // `claw → Claude` and `b code → VS Code` are deliberately absent: they
        // would rewrite ordinary speech. This locks that decision in.
        let dangerous = ["claw", "b code", "the", "code", "flow", "base", "cloud", "claude"]
        let spokenForms = Set(DefaultVocabulary.seed().map(\.spoken))
        for term in dangerous {
            #expect(!spokenForms.contains(term), "'\(term)' is too generic to be a rule")
        }
    }

    @Test("The dictionary leaves ordinary prose completely alone")
    func ordinaryProseIsUntouched() {
        let table = DefaultVocabulary.seed()
        let sentences = [
            "The cloud was grey and the code compiled.",
            "I like the way this flows through the base of the valley.",
            "She opened the door and walked outside into the rain.",
            "El perro corrió por la casa y se subió a la cama.",
            "Su padre llegó tarde a la reunión de la mañana.",
        ]
        for sentence in sentences {
            #expect(VocabularyStage.replace(in: sentence, using: table).text == sentence,
                    "dictionary altered ordinary prose: \(sentence)")
        }
    }

    @Test("A scoped rule cannot fire on the ordinary word it contains")
    func scopedRulesAreSafe() {
        // "supervise" alone is a real English verb, so the rule is scoped to
        // "supervise edge". These must all survive untouched.
        let table = DefaultVocabulary.seed()
        for sentence in ["I supervise the team", "She will supervise tomorrow",
                         "we clock out at five", "the clock out front"] {
            let result = VocabularyStage.replace(in: sentence, using: table).text
            #expect(!result.contains("Supabase"), "false positive on: \(sentence)")
        }
        // "we clock out" IS a real phrase, and this rule does fire on it. That
        // is a deliberate trade: the user dictates technical prose constantly
        // and clocks out never. Recorded so the trade is visible if it bites.
        #expect(VocabularyStage.replace(in: "we clock out at five", using: table).text
                .contains("Claude Code"))
    }

    @Test("The Phase 6 failure now produces the right names")
    func phaseSixRegression() {
        // Live Phase 6 output was: "Deploy the superbase edge functions with
        // cloud code, uncheck cloud flare."
        let table = DefaultVocabulary.seed()
        let result = VocabularyStage.replace(
            in: "Deploy the superbase edge functions with cloud code, uncheck cloud flare.",
            using: table)
        #expect(result.text.contains("Supabase"))
        #expect(result.text.contains("Claude Code"))
        #expect(result.text.contains("Cloudflare"))
    }

    @Test("The Spanish milestone failures now produce the right names")
    func spanishMilestoneRegression() {
        // Live es_ES output was: "escriba los nombres técnicos como supage,
        // Clauud y Clo Code" for "Supabase, Cloudflare y Claude Code".
        let result = VocabularyStage.replace(
            in: "escriba los nombres técnicos como supage, Clauud y Clo Code",
            using: DefaultVocabulary.seed())
        #expect(result.text.contains("Supabase"))
        #expect(result.text.contains("Cloudflare"))
        #expect(result.text.contains("Claude Code"))

        let second = VocabularyStage.replace(
            in: "Quiero configurar su pabase con Clo Code y después revisar el Dashboard.",
            using: DefaultVocabulary.seed())
        #expect(second.text.contains("Supabase"))
        #expect(second.text.contains("Claude Code"))
    }

    @Test("Spanish re-spells English product names differently on every run")
    func spanishVariantsAllResolve() {
        // The core difficulty with Spanish technical dictation: the engine does
        // not mangle an English product name the same way twice. Every one of
        // these came from a real run of the same sentence.
        let table = DefaultVocabulary.seed()
        let supabase = ["su pae", "su pabase", "su papage", "supage", "supaves",
                        "super bes", "superbase", "supa base"]
        for variant in supabase {
            #expect(VocabularyStage.replace(in: "configurar \(variant) hoy", using: table)
                .text.contains("Supabase"), "missed Supabase variant: \(variant)")
        }
        let claudeCode = ["clo code", "clocode", "cloud co", "cloud code",
                          "clock code", "glock code", "claw code"]
        for variant in claudeCode {
            #expect(VocabularyStage.replace(in: "usar \(variant) ahora", using: table)
                .text.contains("Claude Code"), "missed Claude Code variant: \(variant)")
        }
        let cloudflare = ["cloud flare", "cloud flair", "clauud", "claude flair", "cloudflur"]
        for variant in cloudflare {
            #expect(VocabularyStage.replace(in: "revisar \(variant) luego", using: table)
                .text.contains("Cloudflare"), "missed Cloudflare variant: \(variant)")
        }
    }

    @Test("Field-log product names are corrected")
    func fieldLogNames() {
        let table = DefaultVocabulary.seed()
        let cases: [(String, String)] = [
            ("this is AI slope", "AI slop"),
            ("the speech reconnection is wrong", "speech recognition"),
            ("sell it on pay hip or square space", "Payhip"),
        ]
        for (input, expected) in cases {
            #expect(VocabularyStage.replace(in: input, using: table).text.contains(expected),
                    "missed \(expected) in: \(input)")
        }
    }

    @Test("Field-log rules leave the ordinary words they resemble alone")
    func fieldLogRulesAreScoped() {
        // "reconnection" and "slope" are real words; only their technical
        // contexts are rewritten.
        let table = DefaultVocabulary.seed()
        for sentence in ["the network reconnection took a minute",
                         "the ski slope was icy"] {
            #expect(VocabularyStage.replace(in: sentence, using: table).text == sentence,
                    "false positive on: \(sentence)")
        }
    }

    @Test("The milestone live-test failure now produces the right names")
    func milestoneRegression() {
        // Live output was: "Deploy the supervise edge function, we clock out
        // and check cloud flare." Only Cloudflare was corrected.
        let result = VocabularyStage.replace(
            in: "Deploy the supervise edge function, we clock out and check cloud flare.",
            using: DefaultVocabulary.seed())
        #expect(result.text.contains("Supabase"))
        #expect(result.text.contains("Claude Code"))
        #expect(result.text.contains("Cloudflare"))
    }
}

@Suite("Vocabulary warm-up")
struct VocabularyWarmUpTests {

    @Test("Warming compiles every enabled, useful rule and skips the rest")
    func warmUpPopulatesCache() {
        let unique = "warmup\(UUID().uuidString.prefix(6).lowercased()) "
        let rules = [
            VocabularyRule(spoken: unique + "one", replacement: "One"),
            VocabularyRule(spoken: unique + "two", replacement: "Two", isEnabled: false),
            VocabularyRule(spoken: unique + "same", replacement: unique + "same"),
        ]
        let before = VocabularyStage.cache.count
        VocabularyStage.warmUp(rules)
        #expect(VocabularyStage.cache.count == before + 1)
    }
}
