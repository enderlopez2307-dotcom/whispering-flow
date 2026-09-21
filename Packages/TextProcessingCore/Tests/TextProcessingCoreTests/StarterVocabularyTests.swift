import AppKit
import Foundation
import Testing
@testable import TextProcessingCore

/// The starter dictionary is generated (Scripts/vocab/harvest.py), so these tests
/// are what stop a bad harvest from shipping: they hold the safety policy no
/// matter how the rules were produced.
@Suite("Starter vocabulary")
struct StarterVocabularyTests {

    private let seed = DefaultVocabulary.seed()

    @Test("It is large enough to matter and has no duplicate spoken forms")
    func sizeAndUniqueness() {
        #expect(seed.count >= 150, "starter dictionary shrank to \(seed.count) rules")
        let spoken = seed.map { $0.spoken.lowercased() }
        #expect(Set(spoken).count == spoken.count)
    }

    @Test("A hand-checked rule is never overridden by a generated one")
    func handRulesWin() throws {
        let rule = try #require(seed.first { $0.spoken == "cloud flare" })
        #expect(rule.replacement == "Cloudflare")
        #expect(rule.note?.hasPrefix("Phase 6") == true, "the hand-written note must survive: \(rule.note ?? "nil")")
    }

    @Test("Phrases people really say are never rewritten")
    func ordinarySpeechIsUntouched() {
        // Each of these is a trap the harvest found and review refused. If one of
        // these starts changing, a bad rule got through.
        let sentences = [
            "We need to grow our sales force this quarter.",
            "I have to get up early tomorrow.",
            "It has been a long journey and my journey is not over.",
            "After the run we sat in a sauna for an hour.",
            "Hey Jen, are you coming to lunch?",
            "Xavier and Lincoln are both coming.",
            "The test flight of the new aircraft went well.",
            "You can copy it and paste it later.",
            "She brews her own home brew in the garage.",
            "We drove past Windsor on the way.",
            "I read it and then I painted the wall red it was fine.",
            "The OAuth web flow needs a redirect.",
            "Let's lint the code before we merge.",
            "The local host of the tournament gave a speech.",
            "Please watch OS updates carefully.",
            "Some stack of paper fell off the desk.",
            "Two male chimps and a bit of bucket.",
            "El perro corrió por la casa y se subió a la cama.",
            "Ese señor va a pie hasta la tablet de su hija.",
            "Terraforma es el verbo en tercera persona.",
            "La estable difusión de la noticia fue rápida.",
            "Necesito una sana alimentación y un poco de sol.",
        ]
        for sentence in sentences {
            #expect(VocabularyStage.replace(in: sentence, using: seed).text == sentence,
                    "the dictionary altered ordinary speech: \(sentence)")
        }
    }

    @Test("No mishearing rule is a single ordinary English or Spanish word")
    func noSingleOrdinaryWords() {
        let checker = NSSpellChecker.shared
        func isWord(_ word: String, _ language: String) -> Bool {
            checker.checkSpelling(of: word, startingAt: 0, language: language, wrap: false,
                                  inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
        }
        // Rules from before the starter pack, checked by hand when they were
        // observed. Listed so this test is honest about what it is not covering.
        let grandfathered: Set<String> = ["versal", "corsar", "supage", "clauud", "clocode", "bootley"]

        let observed = Set((DefaultVocabulary.observed + StarterVocabulary.observed + PersonalSeed.observed)
            .map { $0.0.lowercased() })
        for rule in seed where observed.contains(rule.spoken.lowercased()) {
            let spoken = rule.spoken.lowercased()
            guard !spoken.contains(" "), !grandfathered.contains(spoken) else { continue }
            #expect(!isWord(spoken, "en_US") && !isWord(spoken, "es_ES"),
                    "'\(spoken)' is an ordinary word; a rule on it would fire on real speech")
        }
    }

    @Test("Multi-word rules never start with a lone letter that could match after an apostrophe")
    func noFragileForms() {
        // Two rules from before the starter pack, observed and hand-checked: spelled
        // letters ("v s code") and one personal field rule. Every newer rule must pass.
        let grandfathered: Set<String> = ["v s code", "u sport lee"]
        for rule in seed where !grandfathered.contains(rule.spoken.lowercased()) {
            let tokens = rule.spoken.split(separator: " ")
            guard tokens.count > 1 else { continue }
            let allSingles = tokens.allSatisfy { $0.count == 1 }
            #expect(tokens[0].count > 1 || allSingles, "fragile form: '\(rule.spoken)'")
            #expect(!rule.spoken.contains(","), "'\(rule.spoken)' contains a comma")
            #expect(!rule.spoken.contains("'"), "'\(rule.spoken)' contains an apostrophe")
        }
    }

    @Test("Casing rules never capitalise a word that is also ordinary Spanish or English prose")
    func casingIsSafe() {
        let mustNotExist = ["veo", "haiku", "prisma", "terraform", "grok", "tailwind", "homebrew", "zoom", "notion"]
        let spoken = Set(seed.map { $0.spoken.lowercased() })
        for word in mustNotExist {
            #expect(!spoken.contains(word), "'\(word)' would rewrite ordinary prose")
        }
    }

    @Test("Names people dictate resolve to the right spelling")
    func namesResolve() {
        let cases: [(String, String)] = [
            ("check calendarly for tomorrow", "Calendly"),
            ("deploy it on versel", "Vercel"),
            ("we use kubernets and doker", "Kubernetes"),
            ("open the deep seek app", "DeepSeek"),
            ("set up post greshel and mongo db", "MongoDB"),
            ("the svelt project", "Svelte"),
            ("ask data dog about it", "Datadog"),
            ("edit it in windsorf", "Windsurf"),
            ("hemos usado antropic", "Anthropic"),
            ("subir el proyecto a jitlab", "GitLab"),
        ]
        for (input, expected) in cases {
            #expect(VocabularyStage.replace(in: input, using: seed).text.contains(expected),
                    "missed \(expected) in: \(input)")
        }
    }
}
