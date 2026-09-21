import AppKit
import SwiftUI
import TextProcessingCore

/// Personal dictionary management. Native and plain on purpose — this is a
/// list of find-and-replace rules, not a place for a design system.
struct VocabularySettingsView: View {

    @Bindable var store: VocabularyStore
    let draft: VocabularyDraft

    @State private var selection: Set<UUID> = []
    @State private var newSpoken = ""
    @State private var newReplacement = ""
    @State private var editing: VocabularyRule?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("When dictation hears the phrase on the left, it writes the text on the right. "
                 + "Quickest way to add one: select a misheard word in any app, then choose "
                 + "Add Correction to Vocabulary… from the menu bar.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Table(store.rules, selection: $selection) {
                TableColumn("On") { rule in
                    Toggle("", isOn: Binding(
                        get: { rule.isEnabled },
                        set: { store.setEnabled($0, for: rule.id) }))
                    .labelsHidden()
                }
                .width(30)

                TableColumn("Heard") { rule in
                    Text(rule.spoken)
                        .foregroundStyle(rule.isEnabled ? .primary : .secondary)
                }
                TableColumn("Written") { rule in
                    Text(rule.replacement)
                        .foregroundStyle(rule.isEnabled ? .primary : .secondary)
                }
                TableColumn("Why") { rule in
                    Text(rule.note ?? "Added by you")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 220)
            .contextMenu(forSelectionType: UUID.self) { ids in
                Button("Edit…") { editing = store.rules.first { ids.contains($0.id) } }
                    .disabled(ids.count != 1)
                Button("Delete", role: .destructive) { store.delete(ids) }
            }

            HStack(spacing: 8) {
                TextField("Heard as", text: $newSpoken)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                TextField("Write instead", text: $newReplacement)
                Button("Add") {
                    store.add(spoken: newSpoken, replacement: newReplacement)
                    newSpoken = ""; newReplacement = ""
                }
                .disabled(!VocabularyRule(spoken: newSpoken, replacement: newReplacement).isUseful)
            }

            HStack {
                Button("Delete Selected", role: .destructive) { store.delete(selection); selection = [] }
                    .disabled(selection.isEmpty)
                Button("Restore Built-ins") { store.restoreBuiltIns() }
                Spacer()
                Button("Show File") {
                    NSWorkspace.shared.activateFileViewerSelecting([store.fileURL])
                }
                Text("\(store.rules.filter(\.isEnabled).count) active")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .onAppear { applyDraft() }
        .onChange(of: draft.revision) { applyDraft() }
        .sheet(item: $editing) { rule in
            VocabularyEditSheet(rule: rule) { updated in
                store.update(updated)
                editing = nil
            } onCancel: {
                editing = nil
            }
        }
    }
}

extension VocabularySettingsView {
    private func applyDraft() {
        guard !draft.spoken.isEmpty else { return }
        newSpoken = draft.spoken
        newReplacement = ""
    }
}

private struct VocabularyEditSheet: View {
    @State var rule: VocabularyRule
    let onSave: (VocabularyRule) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit rule").font(.headline)
            Form {
                TextField("Heard as", text: $rule.spoken)
                TextField("Write instead", text: $rule.replacement)
                Toggle("Enabled", isOn: $rule.isEnabled)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") { onSave(rule) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!rule.isUseful)
            }
        }
        .padding()
        .frame(width: 380)
    }
}
