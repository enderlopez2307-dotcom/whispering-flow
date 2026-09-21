import Foundation
import HotkeyGestureCore
import Testing
@testable import WhisperingFlowKit

private func model(session: SessionState = .idle,
                   preferences: Preferences = .default,
                   permissions: [Permission: PermissionStatus] = allGranted,
                   recoverable: RecoverableTranscript? = nil,
                   launchAtLogin: Bool = false,
                   debug: Bool = false) -> MenuBarModel {
    MenuBarModel.make(session: session,
                      preferences: preferences,
                      permissionStatuses: permissions,
                      latestRecoverable: recoverable,
                      launchAtLogin: launchAtLogin,
                      isDebugBuild: debug)
}

private let allGranted: [Permission: PermissionStatus] = [
    .microphone: .granted, .accessibility: .granted, .inputMonitoring: .granted,
]

private func transcript(_ text: String,
                        outcome: RecoverableTranscript.Outcome) -> RecoverableTranscript {
    RecoverableTranscript(id: UUID(), text: text, capturedAt: Date(),
                          locale: "en-US", outcome: outcome, failureDetail: nil)
}

private extension Array where Element == MenuBarMenuBuilder.Item {
    var titles: [String] { filter { !$0.isSeparator }.map(\.title) }
    func hasAction(_ predicate: (MenuAction) -> Bool) -> Bool {
        contains { $0.action.map(predicate) ?? false }
    }
}

@Suite("Menu bar — every state renders")
struct MenuBarStateCoverageTests {

    @Test("Each session state maps to a distinct menu-bar state and title",
          arguments: [
            (SessionState.idle, MenuBarState.idle, "Ready"),
            (.listening(startedAt: Date()), .listening, "Listening…"),
            (.transcribing, .working, "Transcribing…"),
            (.processing, .working, "Cleaning up…"),
            (.inserting, .working, "Inserting…"),
          ])
    func statesRender(session: SessionState, expected: MenuBarState, title: String) {
        let m = model(session: session)
        #expect(m.state == expected)
        #expect(m.statusTitle == title)
        #expect(!MenuBarMenuBuilder.items(for: m).isEmpty)
    }

    @Test("Blocked and failed states surface a detail line")
    func blockedAndFailedHaveDetail() {
        let blocked = model(session: .blocked(.secureInput(holder: "Terminal")))
        #expect(blocked.state == .blocked)
        #expect(blocked.statusDetail?.contains("Terminal") == true)

        let failed = model(session: .failed(.insertionFailed("no target")))
        #expect(failed.state == .failed)
        #expect(failed.statusDetail == "no target")
    }

    @Test("Every state produces a non-empty icon name and a quit item")
    func everyStateIsRenderable() {
        let sessions: [SessionState] = [
            .idle, .listening(startedAt: Date()), .transcribing, .processing, .inserting,
            .blocked(.missingPermissions([.microphone])),
            .failed(.noSpeechDetected),
        ]
        for session in sessions {
            let m = model(session: session)
            #expect(!m.state.symbolName.isEmpty)
            #expect(!m.state.accessibilityLabel.isEmpty)
            #expect(MenuBarMenuBuilder.items(for: m).hasAction { $0 == .quit })
        }
    }
}

@Suite("Menu bar — transcript recovery (ADR-015)")
struct MenuBarRecoveryTests {

    @Test("An un-inserted transcript is always offered back")
    func unrecoveredTranscriptIsOffered() {
        let entry = transcript("hello world", outcome: .insertionFailed)
        let items = MenuBarMenuBuilder.items(for: model(session: .failed(.insertionFailed("x")),
                                                       recoverable: entry))
        #expect(items.hasAction { if case .copyLastTranscript = $0 { return true }; return false })
        #expect(items.titles.contains("Copy Last Transcript"))
    }

    @Test("A successfully inserted transcript is NOT offered — that would be noise")
    func insertedTranscriptIsNotOffered() {
        let entry = transcript("hello world", outcome: .inserted)
        let items = MenuBarMenuBuilder.items(for: model(recoverable: entry))
        #expect(!items.titles.contains("Copy Last Transcript"))
    }

    @Test("Recovery is offered even while blocked — the text still exists")
    func recoveryOfferedWhileBlocked() {
        let entry = transcript("stranded text", outcome: .blocked)
        let items = MenuBarMenuBuilder.items(
            for: model(session: .blocked(.secureInput(holder: nil)), recoverable: entry))
        #expect(items.titles.contains("Copy Last Transcript"))
    }

    @Test("Long transcripts are previewed, not dumped into the menu")
    func longTranscriptIsTruncated() {
        let long = String(repeating: "word ", count: 80)
        let preview = MenuBarModel.preview(of: long)
        #expect(preview.count <= 42)
        #expect(preview.hasSuffix("…"))
    }

    @Test("Newlines are collapsed so the menu cannot break")
    func newlinesCollapsed() {
        #expect(!MenuBarModel.preview(of: "one\ntwo").contains("\n"))
    }
}

@Suite("Menu bar — permissions and settings")
struct MenuBarPermissionTests {

    @Test("Missing permissions are listed, counted and actionable")
    func missingPermissionsAreActionable() {
        let m = model(permissions: [.microphone: .granted,
                                    .accessibility: .denied,
                                    .inputMonitoring: .denied])
        let items = MenuBarMenuBuilder.items(for: m)
        #expect(items.titles.contains("Permissions: 2 needed"))
        #expect(items.hasAction { $0 == .grantPermission(.accessibility) })
        #expect(items.hasAction { $0 == .grantAllPermissions })
    }

    @Test("All granted shows no request action")
    func allGrantedIsQuiet() {
        let items = MenuBarMenuBuilder.items(for: model())
        #expect(items.titles.contains("Permissions: all granted"))
        #expect(!items.hasAction { $0 == .grantAllPermissions })
    }

    @Test("The configured hotkey is shown, not hardcoded")
    func hotkeyIsFromPreferences() {
        var preferences = Preferences.default
        preferences.hotkey = .key(keyCode: 105, required: [])
        let m = model(preferences: preferences)
        #expect(m.hotkeyDescription == "F13")
        #expect(MenuBarMenuBuilder.items(for: m).titles.contains("Hold F13 to dictate, or double-tap to keep talking"))
    }

    @Test("Default hotkey is Right Command, not Right Option (ADR-014)")
    func defaultHotkeyIsRightCommand() {
        #expect(Preferences.default.hotkey == .bareModifier(.rightCommand))
        #expect(Preferences.default.hotkey.displayName == "Right Command")
    }

    @Test("Fast is the default mode and is checked in the menu")
    func fastIsDefault() {
        #expect(Preferences.default.processingMode == .fast)
        let items = MenuBarMenuBuilder.items(for: model())
        let fast = items.first { $0.title == "Fast" }
        let smart = items.first { $0.title == "Smart" }
        #expect(fast?.isChecked == true)
        #expect(smart?.isChecked == false)
    }

    @Test("Debug items appear only in debug builds")
    func debugItemsGated() {
        #expect(!MenuBarMenuBuilder.items(for: model(debug: false))
            .hasAction { if case .debugForceState = $0 { return true }; return false })
        #expect(MenuBarMenuBuilder.items(for: model(debug: true))
            .hasAction { if case .debugForceState = $0 { return true }; return false })
    }
}

@Suite("Trigger instruction follows the configured mode")
struct TriggerInstructionTests {

    private func model(_ mode: TriggerMode, handsFree: Bool = false) -> MenuBarModel {
        var preferences = Preferences.default
        preferences.triggerMode = mode
        preferences.handsFreeDoubleTap = handsFree
        return MenuBarModel.make(session: .idle,
                                 preferences: preferences,
                                 permissionStatuses: [:],
                                 latestRecoverable: nil,
                                 launchAtLogin: false,
                                 isDebugBuild: false)
    }

    @Test("Hold mode says hold")
    func holdReadsAsHold() {
        let titles = MenuBarMenuBuilder.items(for: model(.hold)).map(\.title)
        #expect(titles.contains("Hold Right Command to dictate"))
    }

    @Test("Hold mode with hands-free on also teaches the double-tap")
    func holdWithHandsFreeMentionsDoubleTap() {
        let titles = MenuBarMenuBuilder.items(for: model(.hold, handsFree: true)).map(\.title)
        #expect(titles.contains("Hold Right Command to dictate, or double-tap to keep talking"))
    }

    @Test("Toggle mode never mentions double-tap, even with the preference on")
    func toggleIgnoresHandsFree() {
        let titles = MenuBarMenuBuilder.items(for: model(.toggle, handsFree: true)).map(\.title)
        #expect(!titles.contains { $0.contains("double-tap") })
    }

    @Test("Toggle mode never says hold")
    func toggleNeverSaysHold() {
        // A toggle-mode app that tells the user to hold looks broken: releasing
        // does nothing, which reads exactly like a dropped key-up.
        let titles = MenuBarMenuBuilder.items(for: model(.toggle)).map(\.title)
        #expect(!titles.contains { $0.hasPrefix("Hold ") })
        #expect(titles.contains("Press Right Command to start, press again to stop"))
    }
}
