import Foundation
import Observation
import TextProcessingCore

/// The user's personal dictionary. Local only — no cloud, no sync.
///
/// Stored as JSON in Application Support rather than `UserDefaults`: it is user
/// data they should be able to find, back up and edit, not a preference.
@MainActor
@Observable
final class VocabularyStore {

    private(set) var rules: [VocabularyRule] = []

    private let url: URL
    /// Bumped when the shipped seed changes, so new built-ins can be offered
    /// without resurrecting ones the user deliberately deleted.
    private static let seedVersionKey = "vocabulary.seedVersion"
    private static let currentSeedVersion = 6

    init(directory: URL? = nil, defaults: UserDefaults = .standard) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhisperingFlow", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.url = base.appendingPathComponent("vocabulary.json")

        load()
        if defaults.integer(forKey: Self.seedVersionKey) < Self.currentSeedVersion {
            mergeSeed()
            defaults.set(Self.currentSeedVersion, forKey: Self.seedVersionKey)
        }
    }

    // MARK: - Editing

    func add(spoken: String, replacement: String) {
        let rule = VocabularyRule(spoken: spoken.trimmingCharacters(in: .whitespaces),
                                  replacement: replacement.trimmingCharacters(in: .whitespaces))
        guard rule.isUseful else { return }
        // Replace an existing rule for the same spoken form rather than adding a
        // second one that can never fire.
        if let index = rules.firstIndex(where: {
            $0.spoken.caseInsensitiveCompare(rule.spoken) == .orderedSame
        }) {
            rules[index].replacement = rule.replacement
            rules[index].isEnabled = true
        } else {
            rules.append(rule)
        }
        save()
    }

    func update(_ rule: VocabularyRule) {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[index] = rule
        save()
    }

    func setEnabled(_ enabled: Bool, for id: UUID) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[index].isEnabled = enabled
        save()
    }

    func delete(_ ids: Set<UUID>) {
        rules.removeAll { ids.contains($0.id) }
        save()
    }

    /// Re-offer the shipped dictionary. Existing rules keep their state.
    func restoreBuiltIns() {
        mergeSeed()
    }

    var activeRules: [VocabularyRule] { rules.filter(\.isEnabled) }

    // MARK: - Persistence

    private func mergeSeed() {
        let known = Set(rules.map { $0.spoken.lowercased() })
        let additions = DefaultVocabulary.seed().filter { !known.contains($0.spoken.lowercased()) }
        guard !additions.isEmpty else { return }
        rules.append(contentsOf: additions)
        save()
        Log.settings.info("vocabulary: added \(additions.count, privacy: .public) built-in rules")
    }

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        do {
            rules = try JSONDecoder().decode([VocabularyRule].self, from: data)
        } catch {
            // A corrupt file must not wipe the user's dictionary silently.
            let backup = url.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: url, to: backup)
            Log.settings.error("vocabulary unreadable (\(error.localizedDescription, privacy: .public)) — kept a copy at \(backup.lastPathComponent, privacy: .public)")
        }
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(rules).write(to: url, options: .atomic)
        } catch {
            Log.settings.error("could not save vocabulary: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Where the file lives, for the settings window's "Show in Finder".
    var fileURL: URL { url }
}
