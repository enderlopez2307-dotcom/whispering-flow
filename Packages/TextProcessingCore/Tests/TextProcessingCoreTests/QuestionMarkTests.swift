import Testing
@testable import TextProcessingCore

private let english = ProcessingContext(locale: .english)
private let spanish = ProcessingContext(locale: .spanish)

private func fix(_ text: String, _ context: ProcessingContext = english) -> String {
    QuestionMarkStage().apply(text, context: context)
}

@Suite("Question marks — real misses from the field log")
struct QuestionMarkFieldTests {

    @Test("The long question the engine ended with a period")
    func longQuestion() {
        let text = "Does that mean that it's gonna take longer for the dictation to appear on the box because of all that milliseconds or because it already takes a while for the text to appear."
        #expect(fix(text).hasSuffix("appear?"))
        #expect(fix(text).dropLast() == text.dropLast())
    }

    @Test("A question after another sentence, with a discourse opener")
    func afterAnotherSentence() {
        #expect(fix("It works. So, does it scale.") == "It works. So, does it scale?")
        #expect(fix("Fine. And is that possible.") == "Fine. And is that possible?")
    }

    @Test("The statement the same field log started with 'When' is left alone")
    func whenStatement() {
        let text = "When I was in my previous chat, it said that we were going to practice the interviews."
        #expect(fix(text) == text)
    }
}

@Suite("Question marks — what becomes a question")
struct QuestionMarkPositiveTests {

    @Test("Auxiliary-first questions", arguments: [
        "Is that possible.", "Are you sure.", "Was it the network.", "Were they late.",
        "Does the app restart.", "Did you save it.", "Can you help me.", "Could we try again.",
        "Would it work.", "Should I deploy now.", "Will it break.", "Am I missing something.",
        "Is Claude Code installed.", "Can Claude read this.",
        "Do you want to continue.", "Have you tried turning it off.", "Has it finished.",
        "Isn't that great.", "Doesn't it work.", "Don't you agree.", "Can't we just ship it.",
    ])
    func yesNo(_ sentence: String) {
        #expect(fix(sentence) == String(sentence.dropLast()) + "?")
    }

    @Test("Wh-questions", arguments: [
        "What is that.", "What are the options.", "Why is the app slow.", "Why is it failing.",
        "How do you do that.", "How does it work.", "How can we fix it.", "Where did you put it.",
        "When will you ship.", "Who is the owner.", "Who was that.", "Which one should we use.",
        "How many users are there.", "How long does it take.", "What if we tried again.",
        "How about we skip it.", "Why can't we do that.",
    ])
    func whQuestions(_ sentence: String) {
        #expect(fix(sentence) == String(sentence.dropLast()) + "?")
    }
}

@Suite("Question marks — statements that borrow a question's opener stay statements")
struct QuestionMarkNegativeTests {

    @Test("Statements and fragments are untouched", arguments: [
        "When I was a kid, we moved.",
        "What I mean is that it works.",
        "What is important is that we ship.",
        "What is needed is more time.",
        "How it works is a mystery.",
        "Why it failed is unclear.",
        "Where we go from here is up to you.",
        "Who knows.",
        "Would love to see it.",
        "Should be fine.",
        "Can't wait to see it.",
        "Couldn't be better.",
        "Doesn't matter.",
        "Didn't work.",
        "Won't happen.",
        "Do it now.",
        "Do that again.",
        "Have a nice day.",
        "Have fun.",
        "Will Smith is coming tomorrow.",
        "Is fine.",
        "May is my birthday month.",
        "It is what it is.",
        "That is possible.",
        "Yes.",
        "Okay.",
        "",
    ])
    func untouched(_ sentence: String) {
        #expect(fix(sentence) == sentence)
    }

    @Test("Existing marks are never overridden")
    func existingMarks() {
        #expect(fix("Is that possible?") == "Is that possible?")
        #expect(fix("Is that possible!") == "Is that possible!")
        #expect(fix("Is that possible…") == "Is that possible…")
        #expect(fix("Wait... is that possible...") == "Wait... is that possible...")
    }

    @Test("Decimals, file names and abbreviations are not sentence ends")
    func notBoundaries() {
        #expect(fix("Is 3.14 close enough.") == "Is 3.14 close enough?")
        #expect(fix("See file.txt is there.") == "See file.txt is there.")
        #expect(fix("Use e.g. is that clear about it.") == "Use e.g. is that clear about it.")
    }

    @Test("Spanish is never touched")
    func spanishUntouched() {
        #expect(fix("Is that possible.", spanish) == "Is that possible.")
        #expect(fix("¿Puedes ayudarme.", spanish) == "¿Puedes ayudarme.")
    }

    @Test("It can be switched off")
    func switchedOff() {
        var context = english
        context.options.fixQuestionMarks = false
        #expect(fix("Is that possible.", context) == "Is that possible.")
    }
}

@Suite("Question marks — structural guarantees")
struct QuestionMarkStructureTests {

    private let samples = [
        "Is that possible. It works. Does it scale. Fine.",
        "What is that.\nIs it big.\nNo.",
        "Okay so, can you hear me. Good. Why is it slow. I don't know.",
        "When I was little. Do you remember. Have a nice day.",
    ]

    @Test("Only a period ever becomes a question mark; length and every other character are unchanged")
    func onlyPeriodsChange() {
        for sample in samples {
            let result = fix(sample)
            #expect(result.count == sample.count)
            for (before, after) in zip(sample, result) where before != after {
                #expect(before == "." && after == "?")
            }
        }
    }

    @Test("Running it twice gives the same result")
    func idempotent() {
        for sample in samples { #expect(fix(fix(sample)) == fix(sample)) }
    }

    @Test("It runs inside the production pipeline, after spacing and before capitalisation")
    func inPipeline() {
        let out = TextPipeline.production.process("does that mean it is slower.", context: english)
        #expect(out.hasPrefix("Does that mean it is slower?"))
    }
}
