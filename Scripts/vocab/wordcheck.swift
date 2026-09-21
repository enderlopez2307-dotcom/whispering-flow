import AppKit
// Reads one token per line on stdin; prints "<token>\t<en>\t<es>" with 1 when the
// macOS spell checker accepts the token as a valid word in that language.
let checker = NSSpellChecker.shared
func valid(_ word: String, _ lang: String) -> Bool {
    let range = checker.checkSpelling(of: word, startingAt: 0, language: lang, wrap: false,
                                      inSpellDocumentWithTag: 0, wordCount: nil)
    return range.location == NSNotFound
}
while let line = readLine() {
    let w = line.trimmingCharacters(in: .whitespaces)
    if w.isEmpty { continue }
    print("\(w)\t\(valid(w, "en_US") ? 1 : 0)\t\(valid(w, "es_ES") ? 1 : 0)")
}
