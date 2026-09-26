import Foundation

/// Rejects a Smart rewrite that changed a fact rather than the wording.
///
/// The length check in `SmartCleanup.sanitize` catches summaries and
/// expansions. These catch the small edits it cannot see, each one seen in a
/// real dictation log (Sept 2026):
/// - "3 were, 2 were on the team" → "3 were on the team": the model collapsed
///   a self-correction and kept the wrong number.
/// - "100 K in sales" → "$100K": it invented a currency the speaker never said.
/// - "a fucking stupid bug" → "a stupid bug": it censored the speaker.
/// - "check if I Massachusetts come" → "check if I come": it deleted a
///   capitalised word, which is how a misrecognised name usually looks.
///
/// A rejection returns the deterministic text, which is always acceptable, so
/// every check leans towards rejecting. Smart is "more polished", never "more
/// accurate" (ADR-022).
enum SmartFidelity {

    /// Why `output` is not a faithful rewrite of `input`, or nil when it is.
    static func violation(input: String, output: String) -> String? {
        let missingNumbers = numbers(in: input).subtracting(numbers(in: output))
        if let number = missingNumbers.sorted().first {
            return "model dropped the number \(number)"
        }
        if currencyCount(output) > currencyCount(input) {
            return "model added a currency symbol"
        }
        let inputSwears = swearCount(input)
        if inputSwears > 0, swearCount(output) < inputSwears {
            return "model removed a swear word"
        }
        let outputWords = Set(words(in: output).flatMap { word in
            [comparable(word)] + word.split(separator: "-").map { comparable(String($0)) }
        })
        if let name = capitalisedMidSentence(input).first(where: { !isKept(comparable($0), in: outputWords) }) {
            return "model dropped the capitalised word \"\(name)\""
        }
        return nil
    }

    /// Digit runs with separators removed, so "100,000" and "100000" match.
    static func numbers(in text: String) -> Set<String> {
        let pattern = try! NSRegularExpression(pattern: "\\p{Nd}+(?:[.,]\\p{Nd}+)*")
        let source = text as NSString
        return Set(pattern.matches(in: text, range: NSRange(location: 0, length: source.length)).map {
            source.substring(with: $0.range).filter(\.isNumber)
        })
    }

    /// Kept, or respelled: one word a prefix of the other ("GitHubub" →
    /// "GitHub", "Kubernet" → "Kubernetes") is the model fixing the name, which
    /// is fine. A word with no relative left in the output is a deletion.
    static func isKept(_ word: String, in outputWords: Set<String>) -> Bool {
        if outputWords.contains(word) { return true }
        return outputWords.contains { other in
            min(other.count, word.count) >= 4 && (other.hasPrefix(word) || word.hasPrefix(other))
        }
    }

    static func currencyCount(_ text: String) -> Int {
        text.filter { "$€£¥₹".contains($0) }.count
    }

    /// Whole words, plus stems that cover their inflections ("fucking",
    /// "shitty"). English and Spanish: the user dictates in both.
    static let swearWords: Set<String> = [
        "damn", "crap", "bitch", "bastard", "asshole", "bullshit", "hell",
        "mierda", "joder", "coño", "puta", "puto", "carajo", "cabrón", "cabron",
        "hostia", "pendejo", "gilipollas",
    ]
    static let swearStems = ["fuck", "shit"]

    static func swearCount(_ text: String) -> Int {
        words(in: text).map(comparable).filter { word in
            swearWords.contains(word) || swearStems.contains(where: { word.hasPrefix($0) })
        }.count
    }

    /// Words the recogniser capitalised although no sentence starts there:
    /// names, products, places. "I" and its contractions are excluded.
    static func capitalisedMidSentence(_ text: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: wordPattern)
        let source = text as NSString
        return pattern.matches(in: text, range: NSRange(location: 0, length: source.length)).compactMap { match in
            let word = source.substring(with: match.range)
            guard let first = word.unicodeScalars.first,
                  CharacterSet.uppercaseLetters.contains(first),
                  word != "I", !word.hasPrefix("I'"), !word.hasPrefix("I’")
            else { return nil }
            let before = source.substring(to: match.range.location)
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”'‘’(¿¡")))
            guard let last = before.last, !".!?:…".contains(last) else { return nil }
            return word
        }
    }

    private static let wordPattern = "\\p{L}[\\p{L}\\p{N}'’-]*"

    static func words(in text: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: wordPattern)
        let source = text as NSString
        return pattern.matches(in: text, range: NSRange(location: 0, length: source.length))
            .map { source.substring(with: $0.range) }
    }

    /// Lowercased, without a possessive, so "Figma's" still counts as keeping
    /// "Figma".
    static func comparable(_ word: String) -> String {
        var lowered = word.lowercased()
        for suffix in ["'s", "’s"] where lowered.hasSuffix(suffix) {
            lowered.removeLast(2)
        }
        return lowered
    }
}
