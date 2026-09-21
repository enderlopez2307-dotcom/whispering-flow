import AppKit
import Foundation
import TextProcessingCore

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {

    public override init() { super.init() }

    private var environment: AppEnvironment?
    private var menuBar: MenuBarController?
    private var settingsWindow: SettingsWindowController?
    private var hud: ListeningHUDController?
    /// Last read of the engine's diagnostics. The engine is an actor, so the
    /// menu cannot read it synchronously; it is refreshed alongside the menu.
    private var speechSummary: String?
    /// The last trace whose Smart fallback the user has already seen by
    /// opening the menu. The warning icon clears once it has been seen.
    private var acknowledgedTrace: ProductionTextProcessor.Trace?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let environment = AppEnvironment()
        self.environment = environment

        Log.app.info("""
            launched — \(environment.buildInfo.bundleIdentifier, privacy: .public) \
            v\(environment.buildInfo.version, privacy: .public) \
            (\(environment.buildInfo.build, privacy: .public))
            """)
        DiagnosticsCommand.logSnapshot(tag: "launch")

        environment.reconcileLaunchAtLogin()

        settingsWindow = SettingsWindowController { [weak self] in
            environment.makeSettingsView { self?.environment?.coordinator.applyPreferences() }
        }

        menuBar = MenuBarController(initialModel: makeModel())
        menuBar?.onAction = { [weak self] action in self?.handle(action) }
        menuBar?.willOpenMenu = { [weak self] in
            self?.acknowledgedTrace = self?.environment?.lastTrace.value
            self?.environment?.permissions.refresh()
            self?.environment?.secureInput.refresh()
            self?.refreshMenu()
        }

        // Live permission and secure-input tracking. Both re-evaluate readiness
        // so the menu reflects reality without a relaunch.
        environment.permissions.start { [weak self] in
            self?.environment?.coordinator.reevaluateReadiness()
            self?.refreshMenu()
        }
        environment.secureInput.start()

        // Poll-driven observation of the parts that have no change notification.
        startStateObservation()

        // Warm the audio path at launch so the first key-press pays only for
        // `engine.start()`. A failure here is not fatal — the microphone may
        // simply not be plugged in yet — and is retried on the first press.
        do {
            try environment.audioCapture.prepare()
        } catch {
            Log.audio.info("audio not ready at launch: \(error.localizedDescription, privacy: .public)")
        }
        // Reserve BOTH locales at launch. Phase 2.5 Q1 established that en_US
        // and es_ES reserve simultaneously (max 5), so EN → ES → EN later costs
        // nothing and needs no restart.
        // Warm the on-device model so the first Smart dictation is not paying
        // first-call load time on top of its own latency.
        if environment.settings.preferences.processingMode == .smart {
            Task { await SmartCleanup.warmUp() }
        }

        Task { [environment] in
            for locale in Preferences.DictationLocale.allCases {
                do {
                    try await environment.speechEngine.prepare(locale: locale.rawValue)
                } catch {
                    Log.speech.error("\(locale.rawValue, privacy: .public) unavailable: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        // Compile the dictionary's patterns now, off the main thread, so a large
        // starter dictionary does not slow the first dictation after launch.
        let warmRules = environment.vocabulary.activeRules
        Task.detached(priority: .utility) { VocabularyStage.warmUp(warmRules) }
        environment.coordinator.start()
        hud = ListeningHUDController(coordinator: environment.coordinator,
                                     audio: environment.audioCapture,
                                     settings: environment.settings)
        hud?.start()
        refreshMenu()
    }

    public func applicationWillTerminate(_ notification: Notification) {
        environment?.coordinator.stop()
        environment?.permissions.stop()
        environment?.secureInput.stop()
        Log.app.info("terminating")
    }

    public func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: - Model

    private func makeModel() -> MenuBarModel {
        guard let environment else {
            return MenuBarModel.make(session: .idle,
                                     preferences: .default,
                                     permissionStatuses: [:],
                                     latestRecoverable: nil,
                                     launchAtLogin: false,
                                     isDebugBuild: BuildInfo.isDebugBuild)
        }
        let diagnostics = environment.hotkeyMonitor.diagnostics
        let trace = environment.lastTrace.value
        Task { [environment] in
            let summary = await environment.speechEngine.diagnostics.summary
            await MainActor.run { self.speechSummary = summary }
        }
        return MenuBarModel.make(
            session: environment.coordinator.state,
            preferences: environment.settings.preferences,
            permissionStatuses: environment.permissions.statuses,
            latestRecoverable: environment.recovery.latestUnrecovered ?? environment.recovery.latest,
            launchAtLogin: environment.settings.preferences.launchAtLogin,
            isDebugBuild: BuildInfo.isDebugBuild,
            hotkeyHealth: diagnostics.health,
            hotkeyHealthDetail: diagnostics.summary,
            hotkeyDebugSummary: environment.hotkeyMonitor.latencySummary,
            captureDebugSummary: environment.audioCapture.diagnostics.summary,
            speechDebugSummary: speechSummary,
            lastTrace: trace,
            smartSkipUnseen: trace?.smartFellBack == true && trace != acknowledgedTrace)
    }

    private func refreshMenu() {
        menuBar?.update(model: makeModel())
    }

    /// Secure input and coordinator state both change without notifications, so
    /// a low-frequency tick keeps the icon honest between menu openings.
    private func startStateObservation() {
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.environment?.coordinator.reevaluateReadiness()
                self?.refreshMenu()
            }
        }
        timer.tolerance = 0.5
    }

    // MARK: - Actions

    private func handle(_ action: MenuAction) {
        guard let environment else { return }
        switch action {
        case .openSettings:
            settingsWindow?.show()

        case .addVocabularyCorrection:
            // Read the selection before Settings takes focus from that app.
            environment.vocabularyDraft.begin(spoken: FocusedAppProbe.selectedText() ?? "")
            settingsWindow?.show()

        case .grantPermission(let permission):
            environment.permissions.revealSettings(for: permission)

        case .grantAllPermissions:
            environment.permissions.requestAll()

        case .copyLastTranscript(let id):
            let copied = environment.recovery.copyToPasteboard(id)
            Log.recovery.info("copy-last-transcript -> \(copied, privacy: .public)")

        case .setProcessingMode(let mode):
            environment.settings.preferences.processingMode = mode
            // Warm the model now, so the first Smart dictation after switching
            // does not also pay first-call load time.
            if mode == .smart { Task { await SmartCleanup.warmUp() } }

        case .setLocale(let locale):
            environment.settings.preferences.locale = locale

        case .toggleLaunchAtLogin:
            let next = !environment.settings.preferences.launchAtLogin
            switch LaunchAtLoginController.setEnabled(next) {
            case .success:
                environment.settings.preferences.launchAtLogin = next
            case .failure(let error):
                presentAlert(title: "Could not change login item",
                             message: error.localizedDescription)
            }

        case .openSecureInputHelp:
            presentAlert(
                title: "Secure input is active",
                message: """
                    Another app has asked macOS to protect keyboard input. While that is true, \
                    no app — including this one — can see the dictation shortcut.

                    Common causes are a password dialog, or Terminal's Secure Keyboard Entry. \
                    Dictation resumes automatically once it is released.
                    """)

        case .quit:
            NSApp.terminate(nil)

        case .debugForceState(let name):
            handleDebug(name)
        }
        refreshMenu()
    }

    private func handleDebug(_ name: String) {
        guard let environment else { return }
        switch name {
        case "idle": environment.coordinator.debugForceState(.idle)
        case "listening": environment.coordinator.debugForceState(.listening(startedAt: Date()))
        case "transcribing": environment.coordinator.debugForceState(.transcribing)
        case "processing": environment.coordinator.debugForceState(.processing)
        case "inserting": environment.coordinator.debugForceState(.inserting)
        case "blocked":
            environment.coordinator.debugForceState(
                .blocked(.secureInput(holder: "Debug")))
        case "failed":
            environment.coordinator.debugForceState(
                .failed(.insertionFailed("Debug failure — transcript should still be recoverable")))
        case "transcript":
            environment.coordinator.debugRecordTranscript(
                "This is a debug transcript that was never inserted.")
        default: break
        }
    }

    private func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        NSApp.setActivationPolicy(.accessory)
    }
}
