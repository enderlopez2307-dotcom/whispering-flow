import Testing
@testable import TextProcessingCore

/// Stand-in for NLLanguageRecognizer: the share of words that are on a small
/// Spanish list. Enough to drive every branch deterministically.
private let spanishWords: Set<String> = [
    "hola", "quiero", "mañana", "vamos", "la", "el", "de", "que", "tengo", "y", "en",
    "para", "reunión", "sea", "a", "vernos", "una", "nueva", "lista", "plan", "está", "lista.", "hoy",
]
private func likelihood(_ text: String) -> Double {
    let words = text.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "ñ" && $0 != "á" })
    guard !words.isEmpty else { return 0 }
    return Double(words.filter { spanishWords.contains(String($0)) }.count) / Double(words.count)
}

/// Words spread evenly over `from…to`, all at one confidence.
private func words(_ text: String, from: Double, to: Double, confidence: Double,
                   endsSegment: Bool = true) -> [TimedWord] {
    let tokens = text.split(separator: " ").map(String.init)
    let step = (to - from) / Double(tokens.count)
    var result = tokens.enumerated().map { index, token in
        TimedWord(text: " " + token, start: from + Double(index) * step,
                  end: from + Double(index + 1) * step, confidence: confidence)
    }
    if endsSegment, !result.isEmpty { result[result.count - 1].endsSegment = true }
    return result
}

private func merge(_ english: [TimedWord], _ spanish: [TimedWord]) -> BilingualMerge.Result {
    BilingualMerge.merge(english: english, spanish: spanish,
                         englishText: BilingualMerge.join(english),
                         spanishText: BilingualMerge.join(spanish),
                         spanishLikelihood: likelihood)
}

@Suite("Automatic English/Spanish merge")
struct BilingualMergeTests {

    @Test("English speech returns the English model's text untouched")
    func englishUntouched() {
        let english = words("Please open the settings window now.", from: 0, to: 3, confidence: 0.8)
        let spanish = words("Please open de settings window now.", from: 0, to: 3, confidence: 0.9)
        let result = BilingualMerge.merge(english: english, spanish: spanish,
                                          englishText: "Please open the settings window now.",
                                          spanishText: "x", spanishLikelihood: likelihood)
        #expect(result.text == "Please open the settings window now.")
        #expect(result.language == .english)
    }

    @Test("A more confident Spanish model does not win on English-looking text")
    func confidenceAloneIsNotEnough() {
        // Benchmark #1 in miniature: the Spanish model was the more confident
        // one on English speech, and wrote English-looking text.
        let english = words("Open the terminal.", from: 0, to: 2, confidence: 0.7)
        let spanish = words("Open Determinal.", from: 0, to: 2, confidence: 0.9)
        #expect(merge(english, spanish).language == .english)
    }

    @Test("Spanish speech returns the Spanish model's text untouched")
    func spanishUntouched() {
        let english = words("Kiero ke la reunion sea manana.", from: 0, to: 3, confidence: 0.3)
        let spanish = words("Quiero que la reunión sea mañana.", from: 0, to: 3, confidence: 0.95)
        let result = BilingualMerge.merge(english: english, spanish: spanish,
                                          englishText: "Kiero ke la reunion sea manana.",
                                          spanishText: "Quiero que la reunión sea mañana.",
                                          spanishLikelihood: likelihood)
        #expect(result.text == "Quiero que la reunión sea mañana.")
        #expect(result.language == .spanish)
    }

    @Test("English then Spanish keeps each part from its own model")
    func mixedSplits() {
        let english = words("Write this to the team.", from: 0, to: 2, confidence: 0.85)
            + words("Kiero ke la reunion, manana", from: 2.5, to: 5, confidence: 0.1)
        let spanish = words("Right this to de team.", from: 0, to: 2, confidence: 0.6, endsSegment: false)
            + words("Quiero que la reunión sea mañana", from: 2.5, to: 5, confidence: 0.95)
        let result = merge(english, spanish)
        #expect(result.isMixed)
        #expect(result.runs == [
            LanguageRun(language: .english, text: "Write this to the team."),
            LanguageRun(language: .spanish, text: "Quiero que la reunión sea mañana"),
        ])
    }

    @Test("A switch closes the sentence the recogniser left open")
    func switchAddsFullStop() {
        let english = words("Kiero ke la reunion manana", from: 0, to: 2.5, confidence: 0.1, endsSegment: false)
            + words("and send it today", from: 3, to: 5, confidence: 0.9)
        let spanish = words("Quiero que la reunión mañana", from: 0, to: 2.5, confidence: 0.95, endsSegment: false)
            + words("an sen it to day", from: 3, to: 5, confidence: 0.4)
        #expect(merge(english, spanish).text == "Quiero que la reunión mañana. and send it today")
    }

    @Test("A sliver too short to judge takes the language around it")
    func sliverFollowsNeighbours() {
        let english = words("Kiero ke la reunion.", from: 0, to: 2, confidence: 0.1)
            + words("plan,", from: 2.2, to: 2.5, confidence: 0.5)
            + words("Tengo una nueva lista hoy.", from: 3, to: 5, confidence: 0.1)
        let spanish = words("Quiero que la reunión.", from: 0, to: 2, confidence: 0.95)
            + words("Tengo una nueva lista hoy.", from: 3, to: 5, confidence: 0.95)
        let result = merge(english, spanish)
        #expect(result.language == .spanish)
        #expect(!result.text.contains("plan,"))
    }

    @Test("Commas from a model that gave up are replaced by the other model's words")
    func emptyEnglishFallsBack() {
        let english = words("Kiero ke la reunion manana.", from: 0, to: 2, confidence: 0.1)
            + words(", , , ,", from: 2.5, to: 4.5, confidence: 0.01)
        let spanish = words("Quiero que la reunión mañana.", from: 0, to: 2, confidence: 0.95)
            + words("Keep it simple please.", from: 2.5, to: 4.5, confidence: 0.5)
        #expect(merge(english, spanish).text
                == "Quiero que la reunión mañana. Keep it simple please.")
    }

    @Test("The word at a switch is not written twice")
    func seamWordNotDuplicated() {
        // Both models heard the last Spanish word; the English model placed it
        // slightly later, past the cut, so it landed in the English stretch.
        let english = words("Kiero ke la reunion", from: 0, to: 2, confidence: 0.1, endsSegment: false)
            + [TimedWord(text: " mañana,", start: 2.15, end: 2.65, confidence: 0.3)]
            + words("and send it today.", from: 3.2, to: 5, confidence: 0.9)
        let spanish = words("Quiero que la reunión", from: 0, to: 2, confidence: 0.95, endsSegment: false)
            + [TimedWord(text: " mañana", start: 2.0, end: 2.5, confidence: 0.95, endsSegment: true)]
            + words("an sen it to day", from: 3.2, to: 5, confidence: 0.4)
        let text = merge(english, spanish).text
        #expect(text == "Quiero que la reunión mañana. and send it today.")
    }

    @Test("English words the Spanish model did not hear at all follow their neighbours")
    func phantomEnglishFollowsNeighbours() {
        // A breath before Spanish speech, which only the English model turned into words.
        let english = words("She's gone.", from: 0, to: 0.8, confidence: 0.4)
            + words("Kiero ke la reunion sea manana.", from: 1.5, to: 4, confidence: 0.2)
        let spanish = words("Quiero que la reunión sea mañana.", from: 1.5, to: 4, confidence: 0.95)
        let result = BilingualMerge.merge(english: english, spanish: spanish,
                                          englishText: "She's gone. Kiero ke la reunion sea manana.",
                                          spanishText: "Quiero que la reunión sea mañana.",
                                          spanishLikelihood: likelihood)
        #expect(result.language == .spanish)
        #expect(result.text == "Quiero que la reunión sea mañana.")
    }

    @Test("Real English between English stretches is kept even if the Spanish model missed it")
    func unheardEnglishKeptInEnglish() {
        let english = words("Send the report today.", from: 0, to: 2, confidence: 0.9)
            + words("Thanks a lot.", from: 2.6, to: 3.4, confidence: 0.8)
            + words("See you on Monday.", from: 4, to: 6, confidence: 0.9)
        let spanish = words("Send de report to day.", from: 0, to: 2, confidence: 0.6)
            + words("See you on Monday.", from: 4, to: 6, confidence: 0.6)
        #expect(merge(english, spanish).text == "Send the report today. Thanks a lot. See you on Monday.")
    }

    @Test("A Spanish word in the English model's text tips a Spanish stretch")
    func spanishWordInEnglishOutput() {
        // English-looking text, confident, but "mañana" gives it away.
        let english = words("Okay so I'll see you mañana.", from: 0, to: 2.5, confidence: 0.8)
            + words("Write the summary for the team.", from: 3, to: 5, confidence: 0.9)
        let spanish = words("Vamos a vernos mañana.", from: 0, to: 2.5, confidence: 0.8)
            + words("Right de summary for de team.", from: 3, to: 5, confidence: 0.6)
        #expect(merge(english, spanish).runs.first
                == LanguageRun(language: .spanish, text: "Vamos a vernos mañana."))
    }

    @Test("A sentence's last word cut off on its own stays with its sentence")
    func lastWordSliverStays() {
        let english = words("Kiero ke la reunion sea", from: 0, to: 2, confidence: 0.1)
            + words("today.", from: 2.05, to: 2.4, confidence: 0.6)
        let spanish = words("Quiero que la reunión sea", from: 0, to: 2, confidence: 0.95)
            + words("today.", from: 2.1, to: 2.4, confidence: 0.6)
        let result = merge(english, spanish)
        #expect(result.language == .spanish)
        #expect(!result.text.contains("sea."))
    }

    @Test("No words at all is English with the engine's text")
    func emptyIsEnglish() {
        let result = BilingualMerge.merge(english: [], spanish: [], englishText: "", spanishText: "",
                                          spanishLikelihood: likelihood)
        #expect(result.language == .english)
        #expect(result.text.isEmpty)
    }
}
