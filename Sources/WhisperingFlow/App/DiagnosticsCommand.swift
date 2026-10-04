import AppKit
import Foundation
import TextProcessingCore

/// Headless entry points, used by the build scripts and for support.
///
/// These run without ever starting the app loop. `--check-permissions` exists
/// for the signing-stability experiment (TECH_RESEARCH §14) and remains useful
/// for diagnosing a permission problem without launching the UI.
public enum DiagnosticsCommand {

    @MainActor
    public static func runIfRequested() -> Bool {
        let arguments = Set(CommandLine.arguments.dropFirst())

        if arguments.contains("--check-permissions") {
            printPermissionReport(json: arguments.contains("--json"))
            return true
        }
        if arguments.contains("--request-permissions") {
            requestAllPermissions()
            return true
        }
        if let index = CommandLine.arguments.firstIndex(of: "--login-item"),
           index + 1 < CommandLine.arguments.count {
            let value = CommandLine.arguments[index + 1]
            switch value {
            case "on", "off":
                let result = LaunchAtLoginController.setEnabled(value == "on")
                switch result {
                case .success: print("login item -> \(value)")
                case .failure(let error): print("FAILED: \(error.localizedDescription)")
                }
            default: break
            }
            print("status: \(LaunchAtLoginController.statusDescription)")
            return true
        }
        if let index = CommandLine.arguments.firstIndex(of: "--validate-corpus") {
            let root = index + 1 < CommandLine.arguments.count
                ? URL(fileURLWithPath: CommandLine.arguments[index + 1])
                : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent("benchmark")
            runCorpusValidation(at: root)
            return true
        }
        if let index = CommandLine.arguments.firstIndex(of: "--process-text"),
           index + 1 < CommandLine.arguments.count {
            processText(CommandLine.arguments[index + 1], spanish: arguments.contains("--es"))
            return true
        }
        if let index = CommandLine.arguments.firstIndex(of: "--transcribe-dir"),
           index + 1 < CommandLine.arguments.count {
            runTranscribeDirectory(at: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            return true
        }
        if let index = CommandLine.arguments.firstIndex(of: "--probe-languages"),
           index + 1 < CommandLine.arguments.count {
            runLanguageProbe(at: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            return true
        }
        if arguments.contains("--probe-focus") {
            probeFocus()
            return true
        }
        if arguments.contains("--version") {
            let info = BuildInfo.current
            print("\(info.bundleIdentifier) \(info.version) (\(info.build))")
            return true
        }
        return false
    }

    /// Dump what the focus probe sees, after a delay long enough to click
    /// somewhere. Used to find out what an app *actually* reports, rather than
    /// what the accessibility documentation implies.
    private static func probeFocus() {
        print("Click where you want to test. Sampling in 5 seconds…")
        Thread.sleep(forTimeInterval: 5)
        let target = FocusedAppProbe.current(timeout: 1.0)
        print("app:        \(target.applicationName ?? "?") (\(target.bundleIdentifier ?? "?"))")
        print("role:       \(target.role ?? "nil")")
        print("subrole:    \(target.subrole ?? "nil")")
        print("confidence: \(target.confidence)")
        if let element = FocusedAppProbe.focusedElementForInsertion(timeout: 1.0) {
            print("ancestors:  \(FocusedAppProbe.ancestorRoles(of: element, limit: 10).joined(separator: " < "))")
        }
        print("allows:     \(target.allowsInsertion)")
        for (label, value) in FocusedAppProbe.debugAttributes() {
            print("  \(label): \(value)")
        }
    }

    /// Replay the Phase 2.5 corpus through the production engine. Headless —
    /// no microphone, no hotkey, no TCC.
    private static func runCorpusValidation(at root: URL) {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var output = ""
        Task {
            let outcomes = await CorpusValidation.run(corpusRoot: root, engine: AppleSpeechEngine())
            output = CorpusValidation.report(outcomes)
            semaphore.signal()
        }
        semaphore.wait()
        print(output)
    }

    /// Run typed text through the same vocabulary and cleanup a dictation gets, and
    /// print the result. No microphone, no model, no changes to any file: it reads
    /// the person's dictionary and prints. Fast-mode behaviour only (Smart needs
    /// Apple Intelligence and is not deterministic).
    ///
    ///     WhisperingFlow --process-text "does that mean it is slower."
    ///     WhisperingFlow --process-text "configurar su pae hoy" --es
    ///
    /// It answers "would this rule or this sentence work?" without speaking, so a
    /// deterministic stage never needs repeated live testing.
    private static func processText(_ text: String, spanish: Bool) {
        let file = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhisperingFlow/vocabulary.json")
        var rules = DefaultVocabulary.seed()
        var source = "shipped dictionary"
        if let data = try? Data(contentsOf: file),
           let stored = try? JSONDecoder().decode([VocabularyRule].self, from: data) {
            rules = stored.filter(\.isEnabled)
            source = "your dictionary (\(rules.count) active rules)"
        }
        let locale: ProcessingContext.DictationLocale = spanish ? .spanish : .english
        let vocabulary = VocabularyStage.replace(in: text, using: rules)
        let result = TextPipeline.production.process(
            vocabulary.text, context: ProcessingContext(locale: locale, vocabulary: []))
        print("language:   \(spanish ? "Spanish" : "English")")
        print("dictionary: \(source)")
        print("in:         \(text)")
        print("out:        \(result.trimmingCharacters(in: .whitespaces))")
        print("rules hit:  \(vocabulary.hits.isEmpty ? "none" : vocabulary.hits.joined(separator: ", "))")
    }

    /// Transcribe every `<id>__<locale>.wav` in a folder and print one JSON line
    /// per file: `{"file":…,"locale":…,"text":…}`. Headless, like the corpus
    /// run. It is how the starter vocabulary is harvested (Scripts/vocab/): speak
    /// known terms with synthetic voices, see what the real recogniser writes.
    private static func runTranscribeDirectory(at directory: URL) {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await CorpusValidation.transcribeDirectory(directory, engine: AppleSpeechEngine())
            semaphore.signal()
        }
        semaphore.wait()
    }

    /// Nonisolated on purpose: a `Task` created inside the main-actor
    /// `runIfRequested` would itself run on the main actor, which the
    /// semaphore is blocking.
    private static func runLanguageProbe(at directory: URL) {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await LanguageProbe.probeDirectory(directory)
            semaphore.signal()
        }
        semaphore.wait()
    }

    /// Trigger each permission request so the app registers with TCC and appears
    /// in the System Settings lists, where the two manual grants can be toggled.
    private static func requestAllPermissions() {
        print("Requesting Microphone access…")
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            let granted = await PermissionProbe.requestMicrophoneAccess()
            print("  Microphone: \(granted ? "granted" : "not granted")")
            semaphore.signal()
        }
        semaphore.wait()

        print("Requesting Input Monitoring access…")
        let hid = PermissionProbe.requestInputMonitoringAccess()
        print("  Input Monitoring: \(hid ? "granted" : "not granted — toggle it in System Settings")")

        print("Requesting Accessibility access…")
        let ax = PermissionProbe.promptForAccessibility()
        print("  Accessibility: \(ax ? "granted" : "not granted — toggle it in System Settings")")

        print("")
        printPermissionReport(json: false)
        logSnapshot(tag: "after-request")
    }

    /// Write the current snapshot to OSLog.
    ///
    /// This is the authoritative readout when the app is launched as an app.
    /// Running the binary from a shell reports the *terminal's* grants, because
    /// TCC attributes a shell-spawned process to its responsible process
    /// (TECH_RESEARCH §15.7).
    static func logSnapshot(tag: String) {
        let snapshot = PermissionProbe.snapshot()
        let summary = Permission.allCases
            .map { "\($0.rawValue)=\((snapshot[$0] ?? .notDetermined).rawValue)" }
            .joined(separator: " ")
        Log.permission.info("[\(tag, privacy: .public)] \(summary, privacy: .public)")
    }

    private static func printPermissionReport(json: Bool) {
        let snapshot = PermissionProbe.snapshot()
        let ordered = Permission.allCases.map { ($0, snapshot[$0] ?? .notDetermined) }

        if json {
            let object = Dictionary(uniqueKeysWithValues: ordered.map { ($0.0.rawValue, $0.1.rawValue) })
            if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
               let text = String(data: data, encoding: .utf8) {
                print(text)
            }
            return
        }

        print("Bundle:    \(BuildInfo.current.bundleIdentifier)")
        for (permission, status) in ordered {
            let name = permission.rawValue.padding(toLength: 17, withPad: " ", startingAt: 0)
            print("\(name) \(status.symbol)")
        }
    }
}
