import Foundation

// Deterministic cleanup. Every stage here must be one that **cannot change
// meaning**. Semantic rewriting, grammar guessing and resolving abandoned
// restarts are Smart mode's job; a deterministic rule that guessed would
// corrupt the transcript with no way for the user to notice.
//
// The governing principle, from the Phase 2.5 benchmark: predictability beats
// aggressive cleanup. When a rule is uncertain, it does nothing.

/// Unicode normalisation, so visually identical text compares and edits
/// consistently downstream.
///
/// **NFC, not NFD.** Spanish `á` must survive as one composed character: macOS
/// text fields accept both, but a decomposed `a` + combining accent breaks
/// word-boundary matching in the vocabulary stage and looks wrong in some apps.
public struct NormalizationStage: TextStage {
    public let id = StageID("normalization")
    public init() {}

    public func apply(_ input: String, context: ProcessingContext) -> String {
        var text = input.precomposedStringWithCanonicalMapping
        // Smart quotes and dashes the recogniser sometimes emits are kept —
        // they are correct typography. Only genuinely invisible characters go.
        text = text.replacingOccurrences(of: "\u{00A0}", with: " ")   // non-breaking space
        text = text.replacingOccurrences(of: "\u{200B}", with: "")    // zero-width space
        text = text.replacingOccurrences(of: "\u{FEFF}", with: "")    // BOM
        return text
    }
}

/// Collapse runs of spaces and tabs; keep paragraph structure.
public struct WhitespaceStage: TextStage {
    public let id = StageID("whitespace")
    public init() {}

    public func apply(_ input: String, context: ProcessingContext) -> String {
        var text = input.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        // Three or more newlines collapse to a paragraph break; two are left
        // alone because the user may have dictated a deliberate paragraph.
        text = text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "[ \\t]+\n", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "\n[ \\t]+", with: "\n", options: .regularExpression)
        return text
    }
}

/// Conservative filler removal.
///
/// Only words that are unambiguously hesitation noise in the given language.
/// Anything that can carry meaning is either excluded entirely or removed only
/// where it is clearly parenthetical.
public struct FillerStage: TextStage {
    public let id = StageID("fillers")
    public init() {}

    /// Unambiguous English hesitation sounds.
    static let englishHard = ["um", "uhm", "uh", "erm", "er", "hmm", "mmm"]

    /// English phrases that are filler often enough to remove, but only when
    /// fenced by punctuation or at a sentence start.
    static let englishSoft = ["you know", "i mean", "like", "basically", "actually", "literally"]

    /// Unambiguous Spanish hesitation sounds.
    ///
    /// **`este`, `pues` and `bueno` are deliberately absent.** `este` is far
    /// more often the demonstrative "this" — an early rule turned
    /// "revises este archivo" into "revises archivo" (benchmark #14). `pues`
    /// and `bueno` routinely open a real sentence, and benchmark #15 and the
    /// Phase 6 live Spanish monologue both begin with "Bueno".
    static let spanishHard = ["eh", "ehh", "mmm"]

    /// Spanish phrases removable only when clearly parenthetical.
    static let spanishSoft = ["o sea", "digamos"]

    /// Words the recogniser writes twice when the speaker stumbles ("my my
    /// week", "the, the, the parser side"). Doubling any of these is never
    /// grammatical. Left out on purpose: "that that" and "had had" are real
    /// English, "is is" occurs ("what it is is"), "in in" ("fill in in pen"),
    /// "a" ("Plan A, a new plan"), and Spanish "la"/"de" (La Liga, De la Cruz).
    static let englishStutter = ["the", "an", "my", "your", "our", "their", "of", "for",
                                 "with", "from", "to", "and", "i", "we"]
    static let spanishStutter = ["el", "los", "las", "un", "una", "mi", "y"]

    public func apply(_ input: String, context: ProcessingContext) -> String {
        guard context.options.removeFillerWords else { return input }
        let spanish = context.locale == .spanish
        var text = input

        for filler in spanish ? Self.spanishHard : Self.englishHard {
            text = Self.removeStandalone(filler, from: text)
        }
        for filler in spanish ? Self.spanishSoft : Self.englishSoft {
            text = Self.removeParenthetical(filler, from: text)
        }
        // After fillers, so "the, um, the" is already "the, the".
        for word in spanish ? Self.spanishStutter : Self.englishStutter {
            text = Self.collapseRepeats(of: word, in: text)
        }
        return text
    }

    /// "the the" / "the, the, the" → "the", keeping the first occurrence's
    /// casing. An apostrophe ends the match, so "I, I'm" is left alone.
    static func collapseRepeats(of word: String, in text: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: word)
        let pattern = "(?<![\\p{L}\\p{N}'’])(\(escaped))(?:,?[ ]+\\1)+(?![\\p{L}\\p{N}'’])"
        return text.replacingOccurrences(of: pattern, with: "$1",
                                         options: [.regularExpression, .caseInsensitive])
    }

    /// Remove the word wherever it stands alone, taking a trailing comma with
    /// it. Unicode boundaries, so "umbrella" and "número" are untouched.
    static func removeStandalone(_ word: String, from text: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: word)
        let pattern = "(?<![\\p{L}\\p{N}])\(escaped)(?![\\p{L}\\p{N}])[,]?[ ]?"
        return text.replacingOccurrences(of: pattern, with: "",
                                         options: [.regularExpression, .caseInsensitive])
    }

    /// Remove only where the word is clearly an aside: fenced by commas, or
    /// opening a sentence and followed by a comma.
    ///
    /// "I like this" and "basically correct" survive, because in both the word
    /// is doing work.
    static func removeParenthetical(_ word: String, from text: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: word)
        let guardClauses = word == "you know"
        var result = text
        // "It was, like, enormous" → "It was enormous". Both commas go: they
        // only existed to fence the filler, and keeping one leaves a comma
        // splice. The trade-off is a genuine comparison fenced by commas
        // ("tall, like, his father") losing its "like"; fenced usage reads as
        // filler often enough to accept that.
        result = remove(",[ ]*\(escaped)[ ]*,", from: result, guardClauses: guardClauses)
        // Sentence-initial "Like, " / "You know, "
        result = remove("(^|(?<=[.?!¿¡]\\s))\(escaped)[ ]*,[ ]*", from: result, guardClauses: false)
        // Trailing ", you know."
        result = remove(",[ ]*\(escaped)(?=[.?!]|$)", from: result, guardClauses: guardClauses)
        return result
    }

    /// Words that, right before "you know", make it a real clause: "just so you
    /// know", "as you know", "what if I say you know". The recogniser often puts
    /// a comma there ("just so, you know."), which looks exactly like the filler.
    /// A missed filler costs a stray phrase; a deleted clause changes what the
    /// user said, so when the lead-in is one of these the phrase stays.
    private static let clauseLeadIn = try! NSRegularExpression(
        pattern: "(?<![\\p{L}\\p{N}])(?:just so|as|if|let|what|how|do|did|say|said)[ ]*$",
        options: [.caseInsensitive])

    private static func remove(_ pattern: String, from text: String, guardClauses: Bool) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return text }
        let source = text as NSString
        let output = NSMutableString(string: text)
        // Back to front, so earlier ranges stay valid while later ones are deleted.
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)).reversed() {
            if guardClauses {
                let before = source.substring(to: match.range.location)
                let scope = NSRange(location: 0, length: (before as NSString).length)
                if clauseLeadIn.firstMatch(in: before, range: scope) != nil { continue }
            }
            output.deleteCharacters(in: match.range)
        }
        return output as String
    }
}

/// Spoken punctuation commands, where the recogniser did not already apply them.
///
/// Apple's engine punctuates well on its own, so this is a small set: only the
/// commands a user says deliberately when the engine would otherwise write the
/// words out.
public struct SpokenPunctuationStage: TextStage {
    public let id = StageID("spoken-punctuation")
    public init() {}

    static let english: [(String, String)] = [
        ("new line", "\n"),
        ("new paragraph", "\n\n"),
    ]
    static let spanish: [(String, String)] = [
        ("nueva línea", "\n"),
        ("nuevo párrafo", "\n\n"),
    ]

    public func apply(_ input: String, context: ProcessingContext) -> String {
        guard context.options.applySpokenPunctuation else { return input }
        var text = input
        for (phrase, replacement) in context.locale == .spanish ? Self.spanish : Self.english {
            let escaped = NSRegularExpression.escapedPattern(for: phrase)
            // Only when the phrase stands alone as a command — fenced by
            // punctuation or string edges. "on a new line of code" survives.
            let pattern = "[ ]*(?<![\\p{L}\\p{N}])\(escaped)(?![\\p{L}\\p{N}])[.,]?[ ]*"
            text = text.replacingOccurrences(of: pattern, with: replacement,
                                             options: [.regularExpression, .caseInsensitive])
        }
        return text
    }
}

/// Spacing around punctuation. Purely mechanical.
public struct PunctuationSpacingStage: TextStage {
    public let id = StageID("punctuation-spacing")
    public init() {}

    public func apply(_ input: String, context: ProcessingContext) -> String {
        var text = input
        // " ,"  → ","
        text = text.replacingOccurrences(of: "[ ]+([,.;:?!])", with: "$1", options: .regularExpression)
        // ",," / ",." → the stronger mark
        text = text.replacingOccurrences(of: "([,;:])[ ]*([.?!])", with: "$2", options: .regularExpression)
        text = text.replacingOccurrences(of: ",{2,}", with: ",", options: .regularExpression)
        // Leading punctuation left behind by filler removal.
        text = text.replacingOccurrences(of: "^[ ]*[,;:][ ]*", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?<=[.?!\n])[ ]*[,;:][ ]*", with: " ", options: .regularExpression)
        // Ensure a space after a comma that runs into a word.
        text = text.replacingOccurrences(of: "([,;:])(?=[\\p{L}])", with: "$1 ", options: .regularExpression)
        text = text.replacingOccurrences(of: "[ ]{2,}", with: " ", options: .regularExpression)
        // "100 K" → "100K": the recogniser spaces the thousands suffix.
        // Uppercase only, so "5 k" in anything else is left alone.
        text = text.replacingOccurrences(of: "(?<=\\p{Nd}) K(?![\\p{L}\\p{N}])", with: "K",
                                         options: .regularExpression)
        return text
    }
}

/// Capitalise sentence starts. **Only ever raises** a lowercase letter, never
/// lowercases — so a vocabulary term's casing and any capital the engine
/// supplied are both safe.
public struct CapitalizationStage: TextStage {
    public let id = StageID("capitalization")
    public init() {}

    public func apply(_ input: String, context: ProcessingContext) -> String {
        guard context.options.fixCapitalization else { return input }
        var characters = Array(input)
        var atSentenceStart = true

        for index in characters.indices {
            let character = characters[index]
            if character.isLetter {
                if atSentenceStart, character.isLowercase {
                    characters[index] = Character(character.uppercased())
                }
                atSentenceStart = false
            } else if character.isNumber {
                atSentenceStart = false
            } else if ".?!¿¡".contains(character) {
                // A period only ends a sentence when whitespace follows it.
                // That single signal covers every case a digit test missed:
                // "2.one" (benchmark #10 produced "2.One"), "3.14", "e.g." and
                // "file.txt" are none of them followed by a space, and
                // "I have 3. Then we go" is.
                let next = index + 1 < characters.endIndex ? characters[index + 1] : " "
                atSentenceStart = character != "." || next.isWhitespace
            } else if character == "\n" {
                atSentenceStart = true
            }
        }
        return String(characters)
    }
}

/// Restore lexical ordinals the recogniser numeralised.
///
/// ADR-014 locks "spoken ordinals stay lexical": saying "first" should write
/// `first`, and the engine writes `1st` (benchmark #1, "my 1st local test").
///
/// Deliberately narrow. `March 3rd` is correct as written — that is how a date
/// is spelled, not a numeralised word — so month names, weekdays and anything
/// followed by a capitalised word (street names) are all excluded. Only 1–10,
/// which is where dictated prose actually uses words.
public struct OrdinalRestorationStage: TextStage {
    public let id = StageID("ordinals")
    public init() {}

    static let english: [String: String] = [
        "1st": "first", "2nd": "second", "3rd": "third", "4th": "fourth", "5th": "fifth",
        "6th": "sixth", "7th": "seventh", "8th": "eighth", "9th": "ninth", "10th": "tenth",
    ]
    static let spanish: [String: String] = [
        "1º": "primero", "2º": "segundo", "3º": "tercero",
        "1ª": "primera", "2ª": "segunda", "3ª": "tercera",
    ]
    /// Contexts where the numeral form is the correct spelling.
    static let dateWords = [
        "january", "february", "march", "april", "may", "june", "july", "august",
        "september", "october", "november", "december",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "enero", "febrero", "marzo", "abril", "mayo", "junio", "julio", "agosto",
        "septiembre", "octubre", "noviembre", "diciembre",
    ]

    public func apply(_ input: String, context: ProcessingContext) -> String {
        let table = context.locale == .spanish ? Self.spanish : Self.english
        var text = input

        for (numeral, word) in table {
            let escaped = NSRegularExpression.escapedPattern(for: numeral)
            // Not preceded by a date word, and not followed by a capitalised
            // word — "March 3rd" and "5th Avenue" both stay as they are.
            // **No `.caseInsensitive`.** Under ICU case-insensitive matching
            // `\p{Lu}` also matches lowercase, which inverted this rule
            // completely: prose ordinals were skipped and dates were rewritten.
            // A capital *then lowercase*: "5th Avenue" stays, but an acronym
            // is not a street name, so "the 1st API release" becomes "first".
            let pattern = "(?<![\\p{L}\\p{N}])\(escaped)(?![\\p{L}\\p{N}])(?![ ]\\p{Lu}\\p{Ll})"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }

            let source = text as NSString
            var output = ""
            var cursor = 0
            for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
                let preceding = source
                    .substring(to: match.range.location)
                    .components(separatedBy: CharacterSet.whitespacesAndNewlines)
                    .last(where: { !$0.isEmpty })?          // skip the separating space
                    .trimmingCharacters(in: .punctuationCharacters)
                    .lowercased() ?? ""
                output += source.substring(with: NSRange(location: cursor,
                                                         length: match.range.location - cursor))
                output += Self.dateWords.contains(preceding)
                    ? source.substring(with: match.range)
                    : word
                cursor = match.range.location + match.range.length
            }
            guard cursor > 0 else { continue }
            output += source.substring(from: cursor)
            text = output
        }
        return text
    }
}

/// Trim, and apply the configured trailing suffix.
public struct TrailingStage: TextStage {
    public let id = StageID("trailing")
    public init() {}

    public func apply(_ input: String, context: ProcessingContext) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return trimmed + context.options.trailingSuffix.literal
    }
}

extension TextPipeline {
    /// The production deterministic pipeline, in locked order (ADR-021).
    ///
    /// Vocabulary runs first so every later stage — capitalisation especially —
    /// sees the corrected product names rather than the recogniser's guesses.
    public static var production: TextPipeline {
        TextPipeline(stages: [
            NormalizationStage(),
            VocabularyStage(),
            SpokenPunctuationStage(),
            FillerStage(),
            OrdinalRestorationStage(),
            PunctuationSpacingStage(),
            QuestionMarkStage(),
            CapitalizationStage(),
            WhitespaceStage(),
            TrailingStage(),
        ])
    }
}
