import AppKit
import Foundation
import SwiftUI

/// Composition root — the only place concrete services are constructed.
///
/// Every dependency is injected from here, so swapping a stub for a real
/// implementation in a later phase is a one-line change and nothing else moves.
@MainActor
final class AppEnvironment {

    let buildInfo: BuildInfo
    let settings: SettingsStore
    let permissions: PermissionCenter
    let secureInput: SecureInputMonitor
    let recovery: TranscriptRecovery
    let coordinator: DictationCoordinator
    let audioCapture: AVAudioEngineCapture
    let speechEngine: AppleSpeechEngine
    let vocabulary: VocabularyStore
    let vocabularyDraft = VocabularyDraft()
    let inserter: InsertionChain

    /// Retained so the menu can surface tap diagnostics and later phases can
    /// replace the remaining stubs.
    let hotkeyMonitor: CGEventTapHotkeyMonitor

    /// Most recent processing trace, so the menu can offer a Fast/Smart
    /// comparison without running the dictation twice.
    let lastTrace = TraceBox()

    @MainActor
    final class TraceBox {
        var value: ProductionTextProcessor.Trace?
    }

    init() {
        let lastTrace = self.lastTrace
        self.buildInfo = BuildInfo.current
        let settings = SettingsStore()
        let permissions = PermissionCenter()
        let secureInput = SecureInputMonitor()
        let recovery = TranscriptRecovery()
        let audioCapture = AVAudioEngineCapture(settings: settings)
        let speechEngine = AppleSpeechEngine()
        let vocabulary = VocabularyStore()
        let inserter = InsertionChain()
        let hotkeyMonitor = CGEventTapHotkeyMonitor(
            binding: settings.preferences.hotkey,
            triggerMode: settings.preferences.triggerMode,
            handsFree: settings.preferences.handsFreeDoubleTap)

        self.settings = settings
        self.permissions = permissions
        self.secureInput = secureInput
        self.recovery = recovery
        self.hotkeyMonitor = hotkeyMonitor
        self.audioCapture = audioCapture
        self.speechEngine = speechEngine
        self.vocabulary = vocabulary
        self.inserter = inserter

        self.coordinator = DictationCoordinator(
            settings: settings,
            permissions: permissions,
            secureInput: secureInput,
            recovery: recovery,
            hotkey: hotkeyMonitor,
            audio: audioCapture,
            speech: speechEngine,
            processor: ProductionTextProcessor(
                // Read at process time, so an edit in settings applies to the
                // very next dictation without a restart.
                vocabulary: { vocabulary.activeRules },
                onTrace: { trace in lastTrace.value = trace }),
            inserter: inserter
        )

        coordinator.latestTrace = { lastTrace.value }

        // A device disconnect must not leave the coordinator in `listening`.
        audioCapture.onCaptureInterrupted = { [coordinator] reason in
            coordinator.handleCaptureInterrupted(reason)
        }
    }

    /// Reconcile the stored login-item flag with the system, which is the real
    /// source of truth — the user can remove a login item while we are not running.
    func reconcileLaunchAtLogin() {
        let actual = LaunchAtLoginController.isEnabled
        if settings.preferences.launchAtLogin != actual {
            Log.app.info("launch-at-login drift: stored \(self.settings.preferences.launchAtLogin, privacy: .public), system \(actual, privacy: .public) — adopting system")
            settings.preferences.launchAtLogin = actual
        }
    }

    func makeSettingsView(onPreferencesChanged: @escaping () -> Void) -> AnyView {
        AnyView(SettingsView(settings: settings,
                             permissions: permissions,
                             secureInput: secureInput,
                             recovery: recovery,
                             vocabulary: vocabulary,
                             draft: vocabularyDraft,
                             onPreferencesChanged: onPreferencesChanged))
    }
}

struct BuildInfo: Sendable {
    let bundleIdentifier: String
    let version: String
    let build: String

    static var current: BuildInfo {
        let info = Bundle.main.infoDictionary
        return BuildInfo(
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "com.whisperingflow.dictation",
            version: info?["CFBundleShortVersionString"] as? String ?? "0",
            build: info?["CFBundleVersion"] as? String ?? "0"
        )
    }

    static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        ProcessInfo.processInfo.arguments.contains("--debug-menu")
        #endif
    }
}
