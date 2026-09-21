import Foundation
import Observation

/// Carries a correction from the moment of failure into the Vocabulary tab.
///
/// Field use showed the fix for misrecognised names — a vocabulary rule — was
/// invisible: three weeks of daily use produced zero user-added rules while the
/// same names failed every day. Selecting the wrong word and choosing "Add
/// Correction to Vocabulary…" puts the lever where the failure is.
@MainActor
@Observable
final class VocabularyDraft {
    enum Tab: Hashable { case general, vocabulary, permissions, history }

    var selectedTab: Tab = .general
    /// Pre-fill for "Heard as". Bumped `revision` re-applies it even when the
    /// same word is chosen twice.
    private(set) var spoken = ""
    private(set) var revision = 0

    func begin(spoken: String) {
        self.spoken = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        selectedTab = .vocabulary
        revision += 1
    }
}
