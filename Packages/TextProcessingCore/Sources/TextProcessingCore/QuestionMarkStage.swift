import Foundation

/// Turns a closing period into a question mark when the sentence is plainly a
/// question by its opening words.
///
/// **Why this exists.** Apple's engine punctuates from the words it hears, and
/// it writes a period after questions that are long or that it heard as
/// statements. In a 56-dictation field log it produced 30 question marks and
/// missed real questions such as "Does that mean that it's going to take longer
/// … or because it already takes a while." Nothing downstream ever adds one, so
/// the user had to type each "?" by hand.
///
/// **It is deliberately narrow, because a wrong "?" is a visible error.** Only a
/// sentence that opens with an auxiliary or wh-word *followed by the kind of
/// word a question puts next* is changed. Statements that borrow the same
/// opener stay statements:
///
/// ```
/// Does that mean it will take longer.        → …longer?
/// When I was in my previous chat, it said.   (unchanged — "When" + "I")
/// What is important is that we ship.         (unchanged — "What is" + adjective)
/// Would love to see it.  Can't wait.         (unchanged — fragments)
/// Do it now.  Have a nice day.               (unchanged — imperatives)
/// ```
///
/// It only ever replaces a "." with a "?". It never adds, removes or reorders a
/// character, never touches a sentence that already has its own mark, and does
/// nothing outside English (Spanish questions are framed with "¿", which this
/// stage does not try to place).
public struct QuestionMarkStage: TextStage {
    public let id = StageID("question-marks")
    public init() {}

    public func apply(_ input: String, context: ProcessingContext) -> String {
        guard context.options.fixQuestionMarks, context.locale == .english else { return input }
        var characters = Array(input)
        var sentenceStart = 0

        for index in characters.indices {
            switch characters[index] {
            case "?", "!", "\n":
                sentenceStart = index + 1
            case ".":
                guard Self.endsSentence(characters, at: index) else { continue }
                let body = String(characters[sentenceStart..<index])
                if Self.isQuestion(body) { characters[index] = "?" }
                sentenceStart = index + 1
            default:
                continue
            }
        }
        return String(characters)
    }

    // MARK: - Sentence boundaries

    /// A period ends a sentence only when whitespace or the end of the text
    /// follows it, it is not part of an ellipsis, and it does not close a
    /// common abbreviation. "3.14", "file.txt" and "e.g. this" are not endings.
    static func endsSentence(_ characters: [Character], at index: Int) -> Bool {
        let next = index + 1 < characters.count ? characters[index + 1] : " "
        guard next.isWhitespace else { return false }
        if index > 0, characters[index - 1] == "." { return false }
        var start = index
        // Letters and inner dots, so "e.g." is read as "e.g", not "g".
        while start > 0, characters[start - 1].isLetter || characters[start - 1] == "." { start -= 1 }
        let word = String(characters[start..<index]).lowercased()
        return !abbreviations.contains(word)
    }

    static let abbreviations: Set<String> = [
        "e.g", "i.e", "vs", "mr", "mrs", "ms", "dr", "etc", "approx", "eg", "ie",
    ]

    // MARK: - Question detection

    static let discourseOpeners: Set<String> = [
        "so", "and", "but", "okay", "ok", "well", "now", "then", "also", "wait",
        "hey", "alright", "actually", "basically",
    ]

    static let pronouns: Set<String> = [
        "i", "you", "he", "she", "it", "we", "they", "this", "that", "these", "those",
        "there", "anyone", "anybody", "everyone", "everybody", "someone", "somebody",
        "nobody",
    ]
    static let determiners: Set<String> = [
        "the", "a", "an", "my", "your", "our", "his", "her", "their", "its",
        "any", "some", "every", "each",
    ]

    /// Auxiliaries that open a yes/no question when a subject follows.
    static let inversionAuxiliaries: Set<String> = [
        "is", "are", "was", "were", "am", "does", "did", "can", "could", "would",
        "should", "shall", "will",
    ]
    /// Negative contractions: a question only when a pronoun follows
    /// ("Isn't it", "Don't you"), never a fragment ("Doesn't matter", "Can't wait").
    static let negativeAuxiliaries: Set<String> = [
        "isn't", "aren't", "wasn't", "weren't", "doesn't", "didn't", "wouldn't",
        "shouldn't", "couldn't", "can't", "won't", "don't",
    ]
    static let whWords: Set<String> = ["what", "why", "how", "where", "when", "who", "whom", "whose", "which"]
    static let whCountWords: Set<String> = ["many", "much", "long", "often", "far", "big", "old", "come", "about"]
    static let whAuxiliaries: Set<String> = [
        "do", "does", "did", "can", "could", "would", "should", "will", "shall", "might",
    ]
    static let beForms: Set<String> = ["is", "are", "was", "were"]

    struct Token {
        let text: String          // lowercased, surrounding punctuation stripped
        let isCapitalized: Bool   // engine capitalises proper nouns; "I" is excluded
    }

    static func tokens(in body: String, limit: Int = 5) -> [Token] {
        var result: [Token] = []
        for raw in body.split(whereSeparator: { $0.isWhitespace }) {
            let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”‘’()[]{}—-,;:").union(.whitespaces))
            // Keep apostrophes inside a word ("isn't"); normalise curly ones.
            let word = trimmed.replacingOccurrences(of: "’", with: "'")
            guard !word.isEmpty else { continue }
            let capital = word.first?.isUppercase == true && word.lowercased() != "i"
            result.append(Token(text: word.lowercased(), isCapitalized: capital))
            if result.count == limit { break }
        }
        return result
    }

    static func isQuestion(_ body: String) -> Bool {
        var words = tokens(in: body)
        // "So, does that mean…", "And is that possible": look past up to two
        // discourse words.
        var skipped = 0
        while skipped < 2, let first = words.first, discourseOpeners.contains(first.text) {
            words.removeFirst()
            skipped += 1
        }
        guard let first = words.first else { return false }
        let second = words.count > 1 ? words[1] : nil
        let third = words.count > 2 ? words[2] : nil

        func subject(_ token: Token?, allowProper: Bool) -> Bool {
            guard let token else { return false }
            if pronouns.contains(token.text) || determiners.contains(token.text) { return true }
            // "Is 5 enough", "Is 3.14 close enough".
            if token.text.first?.isNumber == true { return true }
            return allowProper && token.isCapitalized
        }

        // Yes/no questions.
        if inversionAuxiliaries.contains(first.text) {
            // "Will Smith" is a name; every other opener may take a proper noun.
            return subject(second, allowProper: first.text != "will")
        }
        if negativeAuxiliaries.contains(first.text) {
            guard let second else { return false }
            return pronouns.contains(second.text)
        }
        switch first.text {
        case "do":
            // "Do it." / "Do that." are imperatives.
            guard let second else { return false }
            return ["you", "i", "we", "they", "he", "she", "these", "those", "people",
                    "anyone", "anybody", "everyone"].contains(second.text)
        case "have":
            guard let second else { return false }
            return ["you", "i", "we", "they", "anyone", "anybody", "everyone", "there"].contains(second.text)
        case "has":
            guard let second else { return false }
            return ["he", "she", "it", "anyone", "anybody", "everyone", "there", "this", "that", "the"]
                .contains(second.text)
        default:
            break
        }

        // Wh-questions.
        guard whWords.contains(first.text), let second else { return false }
        if first.text == "what", second.text == "if" { return true }
        if first.text == "how", whCountWords.contains(second.text) { return true }
        if first.text == "which", ["one", "of"].contains(second.text) { return true }

        if beForms.contains(second.text) {
            // "What is that?" / "Why is the app slow?" — but "What is important
            // is…" is a statement, so a determiner or pronoun must follow.
            if ["who", "whom", "whose", "which"].contains(first.text) { return true }
            return subject(third, allowProper: true)
        }
        if whAuxiliaries.contains(second.text) {
            return subject(third, allowProper: true)
        }
        if negativeAuxiliaries.contains(second.text) {
            guard let third else { return false }
            return pronouns.contains(third.text)
        }
        return false
    }
}
