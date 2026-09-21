import AppKit
import HotkeyGestureCore
import SwiftUI

/// The settings window.
///
/// Ordinary window, deliberately: only the Phase 10 listening indicator must be
/// non-activating. A settings window that steals focus is fine, because the user
/// opened it on purpose.
struct SettingsView: View {

    /// Sentinel for "follow the system", which is a nil preference rather than a
    /// pinned device — so changing the system default keeps working.
    private static let systemDefaultTag = "__system_default__"

    @Bindable var settings: SettingsStore
    let permissions: PermissionCenter
    let secureInput: SecureInputMonitor
    let recovery: TranscriptRecovery
    let vocabulary: VocabularyStore
    @Bindable var draft: VocabularyDraft
    let onPreferencesChanged: () -> Void

    var body: some View {
        TabView(selection: $draft.selectedTab) {
            general.tabItem { Label("General", systemImage: "gearshape") }
                .tag(VocabularyDraft.Tab.general)
            VocabularySettingsView(store: vocabulary, draft: draft)
                .tabItem { Label("Vocabulary", systemImage: "character.book.closed") }
                .tag(VocabularyDraft.Tab.vocabulary)
            permissionsTab.tabItem { Label("Permissions", systemImage: "lock.shield") }
                .tag(VocabularyDraft.Tab.permissions)
            history.tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                .tag(VocabularyDraft.Tab.history)
        }
        .frame(width: 620, height: 470)
    }

    // MARK: - General

    private var general: some View {
        Form {
            Section("Dictation") {
                Picker("Hotkey", selection: Binding(
                    get: { settings.preferences.hotkey },
                    set: { settings.preferences.hotkey = $0; onPreferencesChanged() }
                )) {
                    ForEach(HotkeyBinding.selectable, id: \.self) { binding in
                        Text(binding.displayName).tag(binding)
                    }
                }
                Text("Right Option is available but not recommended — it is how you type "
                     + "á, é and ñ, so it collides with writing in Spanish.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Trigger", selection: Binding(
                    get: { settings.preferences.triggerMode },
                    set: { settings.preferences.triggerMode = $0; onPreferencesChanged() }
                )) {
                    Text("Hold to talk").tag(TriggerMode.hold)
                    Text("Press to toggle").tag(TriggerMode.toggle)
                }

                if settings.preferences.triggerMode == .hold {
                    Toggle("Double-tap to keep talking hands-free", isOn: Binding(
                        get: { settings.preferences.handsFreeDoubleTap },
                        set: { settings.preferences.handsFreeDoubleTap = $0; onPreferencesChanged() }
                    ))
                    Text("Tap the hotkey twice quickly to start, tap once to finish, Escape to cancel. "
                         + "It ends by itself after about 5 minutes so the microphone is never left open.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Picker("Language", selection: $settings.preferences.locale) {
                    ForEach(Preferences.DictationLocale.allCases, id: \.self) { locale in
                        Text(locale.title).tag(locale)
                    }
                }
            }

            Section("Microphone") {
                Picker("Input", selection: Binding(
                    get: { settings.preferences.inputDeviceUID ?? Self.systemDefaultTag },
                    set: {
                        settings.preferences.inputDeviceUID =
                            ($0 == Self.systemDefaultTag) ? nil : $0
                        onPreferencesChanged()
                    })) {
                    Text("System default").tag(Self.systemDefaultTag)
                    ForEach(AudioDeviceRegistry.availableInputs()) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                if let uid = settings.preferences.inputDeviceUID,
                   AudioDeviceRegistry.name(forUID: uid) == nil {
                    // The stored device is gone. Capture already falls back, but
                    // silently changing which microphone records is not something
                    // to leave unsaid.
                    Text("The selected microphone is not connected. Recording will use the system default.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Processing") {
                Picker("Mode", selection: $settings.preferences.processingMode) {
                    ForEach(Preferences.ProcessingMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                Text(settings.preferences.processingMode.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Application") {
                Toggle("Launch at login", isOn: Binding(
                    get: { settings.preferences.launchAtLogin },
                    set: { newValue in
                        settings.preferences.launchAtLogin = newValue
                        LaunchAtLoginController.setEnabled(newValue)
                    }
                ))
                Text("Login item status: \(LaunchAtLoginController.statusDescription)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Show the listening waveform", isOn: $settings.preferences.showListeningHUD)
                Toggle("Play feedback sounds", isOn: $settings.preferences.playFeedbackSounds)
            }

            Section("Diagnostics") {
                Toggle("Record transcripts for troubleshooting",
                       isOn: $settings.preferences.recordDiagnosticTranscripts)
                Text("Writes what the recogniser heard, each cleanup stage, the final text, "
                     + "and how it was inserted to a file on this Mac. It is a plaintext record "
                     + "of everything you dictate — leave it off unless you are diagnosing a problem.")
                    .font(.caption)
                    .foregroundStyle(settings.preferences.recordDiagnosticTranscripts ? .orange : .secondary)
                HStack {
                    Button("Show Log") {
                        NSWorkspace.shared.activateFileViewerSelecting([DiagnosticTranscriptLog.url])
                    }
                    Button("Delete Log", role: .destructive) { DiagnosticTranscriptLog.clear() }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Permissions

    private var permissionsTab: some View {
        Form {
            Section("Required") {
                ForEach(Permission.allCases, id: \.self) { permission in
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: permissions.status(of: permission).isGranted
                              ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundStyle(permissions.status(of: permission).isGranted ? .green : .orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(permission.rawValue)
                            Text(permission.rationale)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !permissions.status(of: permission).isGranted {
                            Button("Open…") { permissions.revealSettings(for: permission) }
                        }
                    }
                }
                Button("Request permissions") { permissions.requestAll() }
            }

            Section("Secure input") {
                if secureInput.isActive {
                    Label(secureInput.holderDescription.map { "\($0) is holding secure input" }
                          ?? "Another app is holding secure input",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("While secure input is held, no app can see the dictation shortcut. "
                         + "Terminal's Secure Keyboard Entry and password dialogs both cause this.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label("Not active", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - History

    private var history: some View {
        VStack(alignment: .leading) {
            if recovery.history.isEmpty {
                ContentUnavailableView("No dictations yet",
                                       systemImage: "text.quote",
                                       description: Text("Transcripts appear here so they are never lost."))
            } else {
                List(recovery.history) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.text).lineLimit(3)
                        HStack {
                            Text(entry.outcome.rawValue)
                                .font(.caption)
                                .foregroundStyle(entry.isRecoverable ? .orange : .secondary)
                            Text(entry.capturedAt, style: .time)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Copy") { recovery.copyToPasteboard(entry.id) }
                                .buttonStyle(.link)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding()
    }
}
