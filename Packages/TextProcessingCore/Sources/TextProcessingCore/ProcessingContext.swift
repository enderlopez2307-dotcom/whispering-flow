import Foundation

/// Everything a stage may need to know about *where* this transcript is going.
///
/// The `targetBundleIdentifier` is carried from Phase 1 even though no stage
/// consumes it until Phase 12 (ADR-009). Threading it through later would mean
/// touching every stage signature; carrying it now costs nothing.
public struct ProcessingContext: Sendable, Equatable {
    public enum DictationLocale: String, Sendable, CaseIterable {
        case english = "en"
        case spanish = "es"
    }

    public var locale: DictationLocale
    public var targetBundleIdentifier: String?
    public var vocabulary: [VocabularyRule]
    public var options: ProcessingOptions
    /// Set when Smart mode should run after the deterministic stages. The
    /// deterministic result is produced either way, so a Smart failure always
    /// has something to fall back to.
    public var wantsSmartCleanup: Bool

    public init(
        locale: DictationLocale,
        targetBundleIdentifier: String? = nil,
        vocabulary: [VocabularyRule] = [],
        options: ProcessingOptions = .init(),
        wantsSmartCleanup: Bool = false
    ) {
        self.locale = locale
        self.targetBundleIdentifier = targetBundleIdentifier
        self.vocabulary = vocabulary
        self.options = options
        self.wantsSmartCleanup = wantsSmartCleanup
    }
}

public struct ProcessingOptions: Sendable, Equatable {
    public var removeFillerWords: Bool
    public var applySpokenPunctuation: Bool
    public var fixCapitalization: Bool
    /// Turn a closing period into "?" on sentences that are plainly questions.
    public var fixQuestionMarks: Bool
    public var trailingSuffix: TrailingSuffix

    public enum TrailingSuffix: String, Sendable, CaseIterable {
        case none, space, newline

        public var literal: String {
            switch self {
            case .none: ""
            case .space: " "
            case .newline: "\n"
            }
        }
    }

    public init(
        removeFillerWords: Bool = true,
        applySpokenPunctuation: Bool = true,
        fixCapitalization: Bool = true,
        fixQuestionMarks: Bool = true,
        trailingSuffix: TrailingSuffix = .space
    ) {
        self.removeFillerWords = removeFillerWords
        self.applySpokenPunctuation = applySpokenPunctuation
        self.fixCapitalization = fixCapitalization
        self.fixQuestionMarks = fixQuestionMarks
        self.trailingSuffix = trailingSuffix
    }
}
