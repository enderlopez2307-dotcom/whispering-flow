import Testing
@testable import TextProcessingCore

private func english(_ vocabulary: [VocabularyRule] = []) -> ProcessingContext {
    ProcessingContext(locale: .english, vocabulary: vocabulary)
}
private func spanish(_ vocabulary: [VocabularyRule] = []) -> ProcessingContext {
    ProcessingContext(locale: .spanish, vocabulary: vocabulary)
}
private func run(_ input: String, _ context: ProcessingContext) -> String {
    TextPipeline.production.process(input, context: context).trimmingCharacters(in: .whitespaces)
}

@Suite("Filler removal is conservative")
struct FillerTests {

    @Test("Unambiguous English hesitation is removed")
    func hardFillersGo() {
        #expect(FillerStage().apply("So um I think uh we should go", context: english())
                == "So I think we should go")
    }

    @Test("Words that carry meaning survive")
    func meaningfulWordsSurvive() {
        // Every one of these would be destroyed by a naive filler list, and
        // each changes the sentence's meaning if removed.
        let cases = [
            "I like this design",
            "That is basically correct",
            "The number was umbrella shaped",
            "He is a performer",
            "Actually running the tests is the point",
        ]
        for sentence in cases {
            #expect(FillerStage().apply(sentence, context: english()) == sentence,
                    "filler stage damaged: \(sentence)")
        }
    }

    @Test("Soft fillers go only when clearly parenthetical")
    func softFillersNeedFencing() {
        #expect(FillerStage().apply("It was, like, enormous", context: english())
                == "It was enormous")
        #expect(FillerStage().apply("Like, I told you already", context: english())
                == "I told you already")
        // Not fenced → not touched, because here it is a verb.
        #expect(FillerStage().apply("I like enormous things", context: english())
                == "I like enormous things")
    }

    @Test("\"you know\" stays when it is a real clause, not a filler")
    func youKnowAsAClauseSurvives() {
        // Field bug, 19 Sept 2026: the recogniser writes "just so, you know." and
        // the trailing-filler rule deleted the words the user actually said.
        let kept = [
            "It is not the app, just so, you know.",
            "It is not the app, just so you know.",
            "Tell me, as, you know, I asked.",
            "What if I say, you know, something else",
            "What if I say, you know if there is a change",
        ]
        for sentence in kept {
            #expect(FillerStage().apply(sentence, context: english()) == sentence,
                    "removed a real \"you know\": \(sentence)")
        }
    }

    @Test("\"you know\" is still removed as a filler")
    func youKnowAsFillerStillGoes() {
        #expect(FillerStage().apply("It was, you know, enormous", context: english())
                == "It was enormous")
        #expect(FillerStage().apply("That works, you know.", context: english())
                == "That works.")
        #expect(FillerStage().apply("You know, I told you already", context: english())
                == "I told you already")
        #expect(FillerStage().apply("So, you know, we should go", context: english())
                == "So we should go")
    }

    @Test("Spanish keeps este, pues and bueno")
    func spanishMeaningfulWordsSurvive() {
        // `este` is the demonstrative far more often than a filler — an early
        // rule turned "revises este archivo" into "revises archivo"
        // (benchmark #14). `bueno` and `pues` routinely open a real sentence,
        // and both benchmark #15 and the Phase 6 live monologue start with one.
        let cases = [
            "Quiero que revises este archivo",
            "Bueno, vamos a probar el cambio de idioma",
            "Pues no sé qué decir",
            "Este proyecto está bien",
        ]
        for sentence in cases {
            #expect(FillerStage().apply(sentence, context: spanish()) == sentence,
                    "Spanish filler stage damaged: \(sentence)")
        }
    }

    @Test("Spanish hesitation sounds are removed")
    func spanishHardFillersGo() {
        #expect(FillerStage().apply("el trabajo no va mal eh tengo buen sueldo", context: spanish())
                == "el trabajo no va mal tengo buen sueldo")
    }

    @Test("Filler removal can be turned off entirely")
    func fillersCanBeDisabled() {
        var options = ProcessingOptions(); options.removeFillerWords = false
        let context = ProcessingContext(locale: .english, options: options)
        #expect(FillerStage().apply("um hello", context: context) == "um hello")
    }
}

@Suite("Capitalization only ever raises")
struct CapitalizationTests {

    @Test("Sentence starts are capitalised")
    func sentenceStarts() {
        #expect(CapitalizationStage().apply("hello there. how are you? fine!", context: english())
                == "Hello there. How are you? Fine!")
    }

    @Test("Existing capitals and product names are never lowered")
    func neverLowers() {
        let input = "Open Claude Code and check the Supabase dashboard. VS Code too."
        #expect(CapitalizationStage().apply(input, context: english()) == input)
    }

    @Test("A decimal point is not a sentence end")
    func decimalsAreNotSentences() {
        // Benchmark #10 produced "version 2.One" before this guard existed.
        #expect(CapitalizationStage().apply("we are on version 2.one now", context: english())
                == "We are on version 2.one now")
        #expect(CapitalizationStage().apply("the value is 3.14 exactly", context: english())
                == "The value is 3.14 exactly")
    }

    @Test("Spanish inverted punctuation opens a sentence")
    func spanishOpeners() {
        #expect(CapitalizationStage().apply("¿qué tal? ¡bien!", context: spanish()) == "¿Qué tal? ¡Bien!")
    }

    @Test("Applying twice changes nothing")
    func idempotent() {
        let once = CapitalizationStage().apply("hello there. how are you?", context: english())
        #expect(CapitalizationStage().apply(once, context: english()) == once)
    }
}

@Suite("Spoken ordinals stay lexical (ADR-014)")
struct OrdinalTests {

    @Test("A numeralised ordinal in prose is restored to a word")
    func proseOrdinalsRestored() {
        // Benchmark #1: spoken "my first local test" came back as "my 1st".
        #expect(OrdinalRestorationStage().apply("This is my 1st local test.", context: english())
                == "This is my first local test.")
    }

    @Test("Dates keep their numeral form")
    func datesAreLeftAlone() {
        // "March third" is *spelled* March 3rd. Benchmark #10.
        #expect(OrdinalRestorationStage().apply("Let's meet on March 3rd", context: english())
                == "Let's meet on March 3rd")
        #expect(OrdinalRestorationStage().apply("due Friday 2nd", context: english())
                == "due Friday 2nd")
    }

    @Test("Addresses keep their numeral form")
    func addressesAreLeftAlone() {
        #expect(OrdinalRestorationStage().apply("she lives on 5th Avenue", context: english())
                == "she lives on 5th Avenue")
    }

    @Test("The pipeline never converts a word into an ordinal")
    func neverNumeralises() {
        let text = "the first attempt and the second one"
        #expect(run(text, english()).contains("first"))
        #expect(!run(text, english()).contains("1st"))
    }
}

@Suite("Mechanical cleanup")
struct MechanicalTests {

    @Test("Punctuation spacing is normalised")
    func punctuationSpacing() {
        #expect(PunctuationSpacingStage().apply("hello , world . yes", context: english())
                == "hello, world. yes")
        #expect(PunctuationSpacingStage().apply("wait,,, what", context: english()) == "wait, what")
        #expect(PunctuationSpacingStage().apply("hello,world", context: english()) == "hello, world")
    }

    @Test("Leading punctuation left by filler removal is dropped")
    func leadingPunctuationCleaned() {
        #expect(PunctuationSpacingStage().apply(", so anyway", context: english()) == "so anyway")
    }

    @Test("Spanish accents survive normalisation as composed characters")
    func accentsSurviveComposed() {
        let decomposed = "informacio\u{0301}n ra\u{0301}pida"
        let output = NormalizationStage().apply(decomposed, context: spanish())
        #expect(output == "información rápida")
        #expect(output.unicodeScalars.count < decomposed.unicodeScalars.count, "must be composed, NFC")
    }

    @Test("Invisible characters are stripped, real typography is kept")
    func invisiblesOnly() {
        #expect(NormalizationStage().apply("a\u{200B}b\u{00A0}c", context: english()) == "ab c")
        let typographic = "It's a “quote” — and a dash"
        #expect(NormalizationStage().apply(typographic, context: english()) == typographic)
    }

    @Test("Paragraph structure survives whitespace collapsing")
    func multilineSurvives() {
        #expect(WhitespaceStage().apply("one\n\ntwo\n\n\n\nthree", context: english())
                == "one\n\ntwo\n\nthree")
        #expect(WhitespaceStage().apply("a  \n  b", context: english()) == "a\nb")
    }

    @Test("Spoken newline commands are honoured, ordinary usage is not")
    func spokenNewlines() {
        #expect(SpokenPunctuationStage().apply("first line new line second line", context: english())
                == "first line\nsecond line")
        // "a new line of code" is prose, not a command.
        #expect(SpokenPunctuationStage().apply("add a newline character", context: english())
                == "add a newline character")
    }
}

@Suite("End-to-end deterministic pipeline")
struct PipelineIntegrationTests {

    @Test("The Phase 6 technical sentence comes out correct")
    func technicalSentenceIsFixed() {
        let input = "deploy the superbase edge functions with cloud code, uncheck cloud flare."
        #expect(run(input, english(DefaultVocabulary.seed()))
                == "Deploy the Supabase edge functions with Claude Code, uncheck Cloudflare.")
    }

    @Test("A Spanish technical sentence keeps its English product names")
    func spanishTechnicalSentence() {
        let input = "quiero configurar superbase con cloud code y después revisar el duchboard"
        #expect(run(input, spanish(DefaultVocabulary.seed()))
                == "Quiero configurar Supabase con Claude Code y después revisar el dashboard",
                "the pipeline must not invent a terminal period the speaker did not dictate")
    }

    @Test("No semantic rewriting occurs — a messy self-correction survives intact")
    func selfCorrectionsAreNotResolved() {
        // Resolving abandoned restarts is Smart mode's job. A deterministic
        // rule that guessed here would silently change what the user said.
        let input = "change authentication, no actually onboarding, in the settings screen"
        let output = run(input, english())
        #expect(output.contains("authentication"))
        #expect(output.contains("onboarding"))
    }

    @Test("Ordinary prose passes through essentially unchanged")
    func proseIsPreserved() {
        let input = "The meeting went well and everyone agreed on the plan for next quarter."
        #expect(run(input, english(DefaultVocabulary.seed())) == input)
    }

    @Test("Multiline text survives the whole pipeline")
    func multilineSurvivesPipeline() {
        let output = run("first paragraph\n\nsecond paragraph", english())
        #expect(output.contains("\n\n"))
        #expect(output.hasPrefix("First paragraph"))
        #expect(output.contains("Second paragraph"))
    }

    @Test("A long transcript is not truncated")
    func longTextSurvives() {
        let sentence = "This is a sentence that carries some real content. "
        let input = String(repeating: sentence, count: 200)
        let output = run(input, english())
        #expect(output.count > input.count - 100, "pipeline lost \(input.count - output.count) characters")
    }

    @Test("Empty and whitespace-only input produce nothing, not a stray space")
    func emptyInput() {
        #expect(TextPipeline.production.process("", context: english()).isEmpty)
        #expect(TextPipeline.production.process("   \n  ", context: english()).isEmpty)
    }

    @Test("The pipeline is deterministic — same input, same output, every time")
    func deterministic() {
        let input = "um so deploy the superbase thing with cloud code"
        let context = english(DefaultVocabulary.seed())
        let first = TextPipeline.production.process(input, context: context)
        for _ in 0..<20 {
            #expect(TextPipeline.production.process(input, context: context) == first)
        }
    }

    @Test("Stage order is the locked production order (ADR-021)")
    func stageOrderIsLocked() {
        // Vocabulary must precede capitalisation, or product names get sentence
        // casing applied to the recogniser's wrong guess instead.
        let ids = TextPipeline.production.stages.map(\.id.rawValue)
        let vocabulary = ids.firstIndex(of: "vocabulary")!
        #expect(vocabulary < ids.firstIndex(of: "capitalization")!)
        #expect(vocabulary < ids.firstIndex(of: "fillers")!)
        #expect(ids.last == "trailing")
    }
}

@Suite("The pipeline cannot corrupt characters inside a word (field feedback §2)")
struct CharacterIntegrityTests {

    /// Letters only, case folded, so the only permitted differences — sentence
    /// capitalisation and whole-word vocabulary or filler edits — do not count.
    private func letters(_ text: String) -> String {
        text.lowercased().filter(\.isLetter)
    }

    @Test("Field-log corruptions cannot be produced from their correct spellings")
    func fieldLogCorruptionsAreNotPipelineOutput() {
        // Field log, left in inserted text: profitbale, macthes, defintiely,
        // pragraph, professionak, aquire, axctually, Anyyone, ANyone.
        // Run every correct spelling through the whole production pipeline in
        // every sentence position and confirm each comes out intact.
        let words = ["profitable", "matches", "definitely", "paragraph",
                     "professional", "acquire", "actually", "anyone"]
        let table = DefaultVocabulary.seed()
        for word in words {
            for sentence in ["\(word)", "this is \(word) here", "so. \(word) now",
                             "we said \(word), and \(word) again"] {
                for locale in [ProcessingContext.DictationLocale.english, .spanish] {
                    let output = TextPipeline.production.process(
                        sentence, context: ProcessingContext(locale: locale, vocabulary: table))
                    #expect(letters(output).contains(word),
                            "pipeline altered '\(word)' in '\(sentence)' → '\(output)'")
                }
            }
        }
    }

    @Test("Capitalisation can only ever raise the first letter of a sentence")
    func noMidWordCapitals() {
        // "ANyone" needs a capital on the second letter. No stage can do that.
        let output = TextPipeline.production.process(
            "anyone there. anyone else? anyone",
            context: ProcessingContext(locale: .english))
        for word in output.split(whereSeparator: { !$0.isLetter }) {
            #expect(word.dropFirst().allSatisfy { !$0.isUppercase },
                    "mid-word capital produced: \(word)")
        }
    }
}
