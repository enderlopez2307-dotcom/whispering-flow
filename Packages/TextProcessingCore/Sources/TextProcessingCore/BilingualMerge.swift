import Foundation

/// One recognised word with its place in the audio, as Apple's transcriber
/// reports it (`audioTimeRange` and `transcriptionConfidence` per run).
public struct TimedWord: Sendable, Equatable {
    public var text: String
    public var start: Double
    public var end: Double
    public var confidence: Double
    /// The recogniser closed a result after this word: a pause it heard.
    public var endsSegment: Bool

    public init(text: String, start: Double, end: Double, confidence: Double, endsSegment: Bool = false) {
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
        self.endsSegment = endsSegment
    }

    var midpoint: Double { (start + end) / 2 }
}

public enum SpokenLanguage: String, Sendable, Equatable {
    case english, spanish
}

/// A stretch of the dictation in one language.
public struct LanguageRun: Sendable, Equatable {
    public var language: SpokenLanguage
    public var text: String

    public init(language: SpokenLanguage, text: String) {
        self.language = language
        self.text = text
    }
}

/// Automatic English/Spanish: both recognisers hear the whole dictation, and
/// each stretch of speech is taken from the one that understood it.
///
/// **Why both signals, never one.** On the author's 20 benchmark recordings the
/// Spanish model was sometimes *more* confident on English speech than the
/// English model ("Open Determinal", 0.88 vs 0.71), so confidence alone picks
/// wrong. And language identification of the Spanish model's text alone is
/// fooled by English speech that it re-spells into Spanish-looking words. A
/// stretch becomes Spanish only when the Spanish model's text reads as Spanish
/// **and** the English model visibly failed there (its text reads as Spanish,
/// it heard nothing, or its confidence is far below the Spanish model's).
///
/// **English is the default.** Every doubt resolves to English, and a dictation
/// in which nothing qualifies returns the English text exactly as the engine
/// wrote it, so English-only use is unchanged.
public enum BilingualMerge {

    /// Spanish wins only when the Spanish model's text is at least this Spanish.
    static let spanishTextThreshold = 0.9
    /// …and the English model's text is at least this Spanish,
    static let englishTextLooksSpanish = 0.5
    /// …or the Spanish model is this much more confident.
    static let confidenceMargin = 0.25
    /// Below this many letters a stretch is too short to identify by text.
    static let minimumLetters = 6
    /// A single word this Spanish in the English model's output is a tell.
    /// "publico" 0.99, "hola" 0.98; shared words stay under: "solo" 0.92, "plan" 0.56.
    static let spanishWordThreshold = 0.95
    /// Stretches of at most this many words on both sides follow their neighbours.
    static let sliverWords = 2
    /// At most this many English words with no Spanish counterpart count as a phantom.
    static let phantomWords = 3
    /// A silence this long in either model's words is a place a switch can happen.
    static let pauseSeconds = 0.35

    public struct Result: Sendable, Equatable {
        public var runs: [LanguageRun]
        public var text: String { runs.map(\.text).joined(separator: " ") }
        public var isMixed: Bool { Set(runs.map(\.language)).count > 1 }
        /// The single language of the dictation, or nil when it is mixed.
        public var language: SpokenLanguage? { isMixed ? nil : runs.first?.language ?? .english }
    }

    /// - Parameters:
    ///   - spanishLikelihood: probability, 0…1, that a text is Spanish rather
    ///     than English. Injected so this stays pure; the app passes
    ///     `NLLanguageRecognizer` constrained to the two languages.
    public static func merge(english: [TimedWord],
                             spanish: [TimedWord],
                             englishText: String,
                             spanishText: String,
                             spanishLikelihood: (String) -> Double) -> Result {
        let units = makeUnits(english: english, spanish: spanish)
        let verdicts = resolve(units.map {
            decide(english: $0.english, spanish: $0.spanish, spanishLikelihood: spanishLikelihood)
        })
        let decided: [(SpokenLanguage, [TimedWord])] = zip(units, verdicts).map { unit, language in
            if language == .spanish { return (language, unit.spanish) }
            // The English model sometimes gives up on a stretch and writes only
            // commas; the Spanish model's attempt at the same words beats nothing.
            if letterCount(join(unit.english)) == 0 { return (language, unit.spanish) }
            return (language, unit.english)
        }

        // Whole dictation in one language: the engine's own text for that
        // model, untouched. Only a genuinely mixed dictation is reassembled.
        let languages = Set(decided.filter { !$0.1.isEmpty }.map(\.0))
        if languages.isEmpty || languages == [.english] {
            return Result(runs: [LanguageRun(language: .english, text: englishText)])
        }
        if languages == [.spanish] {
            return Result(runs: [LanguageRun(language: .spanish, text: spanishText)])
        }

        var runs: [LanguageRun] = []
        var lastKept: TimedWord?
        var lastLanguage: SpokenLanguage?
        for (language, unitWords) in decided where !unitWords.isEmpty {
            var words = unitWords
            // At a switch, the two models place the same spoken word a little
            // differently, so the word at the seam can land on both sides of the
            // cut and be written twice ("…sea mañana. Mañana, and…", live test 3 Oct).
            // A word that mostly overlaps the last word already kept is that echo.
            if let previous = lastKept, language != lastLanguage {
                words.removeAll { overlap($0, previous) >= 0.5 }
            }
            guard let last = words.last else { continue }
            lastKept = last
            lastLanguage = language
            let text = join(words)
            guard !text.isEmpty else { continue }
            if let last = runs.last, last.language == language {
                runs[runs.count - 1].text = last.text + " " + text
            } else {
                runs.append(LanguageRun(language: language, text: text))
            }
        }
        // A switch of language is a switch of sentence: close the previous one
        // if the recogniser left it open.
        for index in runs.indices.dropLast() where !endsWithPunctuation(runs[index].text) {
            runs[index].text += "."
        }
        return Result(runs: runs)
    }

    // MARK: - Units

    struct Unit {
        var english: [TimedWord] = []
        var spanish: [TimedWord] = []
    }

    /// Cut the timeline wherever either model ended a sentence, ended a
    /// result, or paused. The two models segment differently (the Spanish one
    /// often returns one result spanning both languages), so neither model's
    /// results alone can be the unit; each word then belongs to the unit
    /// holding its midpoint.
    static func makeUnits(english: [TimedWord], spanish: [TimedWord]) -> [Unit] {
        var cuts: [Double] = []
        for words in [english, spanish] {
            for (index, word) in words.enumerated() {
                if word.endsSegment || endsWithSentenceMark(word.text) { cuts.append(word.end) }
                if index + 1 < words.count, words[index + 1].start - word.end >= pauseSeconds {
                    cuts.append((word.end + words[index + 1].start) / 2)
                }
            }
        }
        cuts.sort()
        var bounds: [Double] = []
        for cut in cuts where bounds.last.map({ cut - $0 > 0.15 }) ?? true { bounds.append(cut) }

        var units = Array(repeating: Unit(), count: bounds.count + 1)
        func slot(_ time: Double) -> Int { bounds.firstIndex(where: { time < $0 }) ?? bounds.count }
        for word in english { units[slot(word.midpoint)].english.append(word) }
        for word in spanish { units[slot(word.midpoint)].spanish.append(word) }
        return units.filter { !$0.english.isEmpty || !$0.spanish.isEmpty }
    }

    enum Verdict: Equatable { case english, spanish, tooShort }

    /// A stretch too short to identify ("plan," left over at a boundary) takes
    /// the language around it: Spanish only when every neighbour it has is
    /// Spanish, otherwise English. Without this, a one-word sliver of the
    /// English model's guess was stitched into the middle of Spanish speech.
    static func resolve(_ verdicts: [Verdict]) -> [SpokenLanguage] {
        verdicts.indices.map { index in
            switch verdicts[index] {
            case .english: return .english
            case .spanish: return .spanish
            case .tooShort:
                let before = verdicts[..<index].last { $0 != .tooShort }
                let after = verdicts[(index + 1)...].first { $0 != .tooShort }
                let neighbours = [before, after].compactMap { $0 }
                return !neighbours.isEmpty && neighbours.allSatisfy { $0 == .spanish } ? .spanish : .english
            }
        }
    }

    static func decide(english: [TimedWord], spanish: [TimedWord],
                       spanishLikelihood: (String) -> Double) -> Verdict {
        let spanishText = join(spanish)
        if letterCount(spanishText) < minimumLetters,
           letterCount(join(english)) < minimumLetters { return .tooShort }
        // One or two words cannot be identified, and a sentence's last word
        // often lands alone between two cuts: "…que sea" + "today." got a
        // full stop in the middle (live test 3 Oct).
        if wordCount(spanish) <= sliverWords, wordCount(english) <= sliverWords { return .tooShort }
        // The Spanish model writes *something* for real English speech (it
        // re-spells it). Where it heard nothing at all, a few English words are
        // most likely the English model inventing them from a breath or click:
        // a short English phrase before a purely Spanish sentence (live test 3 Oct). Let
        // such a stretch follow its neighbours instead of defaulting to English.
        if letterCount(spanishText) == 0,
           english.filter({ letterCount($0.text) > 0 }).count <= phantomWords { return .tooShort }
        guard letterCount(spanishText) >= minimumLetters,
              spanishLikelihood(spanishText) >= spanishTextThreshold
        else { return .english }

        let englishText = join(english)
        if letterCount(englishText) == 0 { return .spanish }
        if letterCount(englishText) >= minimumLetters,
           spanishLikelihood(englishText) >= englishTextLooksSpanish { return .spanish }
        // A plainly Spanish word in the English model's text ("see you mañana"
        // for "vamos a vernos mañana") means it was hearing Spanish, even when the
        // rest reads as English and it sounded sure of itself.
        if english.contains(where: { word in
            let letters = word.text.filter(\.isLetter)
            return letters.count >= 4 && spanishLikelihood(String(letters)) >= spanishWordThreshold
        }) { return .spanish }
        return confidence(spanish) - confidence(english) >= confidenceMargin ? .spanish : .english
    }

    /// Share of `word`'s duration that falls inside `other`.
    static func overlap(_ word: TimedWord, _ other: TimedWord) -> Double {
        let shared = min(word.end, other.end) - max(word.start, other.start)
        let duration = word.end - word.start
        guard shared > 0 else { return 0 }
        return duration > 0 ? shared / duration : 1
    }

    // MARK: - Text

    /// Character-weighted, so one confident "I" cannot outvote a sentence.
    static func confidence(_ words: [TimedWord]) -> Double {
        var weighted = 0.0
        var count = 0
        for word in words {
            let letters = max(letterCount(word.text), 1)
            weighted += word.confidence * Double(letters)
            count += letters
        }
        return count > 0 ? weighted / Double(count) : 0
    }

    static func join(_ words: [TimedWord]) -> String {
        words.map { $0.text.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .replacingOccurrences(of: " ([,.;:?!])", with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    static func wordCount(_ words: [TimedWord]) -> Int { words.filter { letterCount($0.text) > 0 }.count }

    static func letterCount(_ text: String) -> Int { text.unicodeScalars.filter(CharacterSet.letters.contains).count }

    static func endsWithSentenceMark(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespaces).last else { return false }
        return ".?!…".contains(last)
    }

    static func endsWithPunctuation(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespaces).last else { return false }
        return ".?!…,;:".contains(last)
    }
}
