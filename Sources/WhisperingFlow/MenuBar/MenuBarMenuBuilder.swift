import AppKit
import Foundation

/// Menu item identities, so tests and handlers refer to items by meaning rather
/// than by index or title string.
enum MenuAction: Equatable, Sendable {
    case openSettings
    case addVocabularyCorrection
    case grantPermission(Permission)
    case grantAllPermissions
    case copyLastTranscript(UUID)
    case setProcessingMode(Preferences.ProcessingMode)
    case setLocale(Preferences.DictationLocale)
    case toggleLaunchAtLogin
    case openSecureInputHelp
    case quit
    case debugForceState(String)
}

/// Builds the menu as a pure function of `MenuBarModel`.
///
/// Pure so that "does the menu show Copy Last Transcript after an insertion
/// failure?" is a unit test, not a manual click-through.
enum MenuBarMenuBuilder {

    struct Item: Equatable, Sendable {
        var title: String
        var action: MenuAction?
        var isEnabled: Bool = true
        var isSeparator: Bool = false
        var isChecked: Bool = false
        var indented: Bool = false
        var submenu: [Item] = []

        static let separator = Item(title: "", action: nil, isSeparator: true)
    }

    static func items(for model: MenuBarModel) -> [Item] {
        var items: [Item] = []

        // Status
        items.append(Item(title: model.statusTitle, action: nil, isEnabled: false))
        if let detail = model.statusDetail {
            items.append(Item(title: detail, action: nil, isEnabled: false, indented: true))
        }
        if let notice = model.processingNotice {
            items.append(Item(title: notice, action: nil, isEnabled: false, indented: true))
        }
        if model.state == .blocked, case .blocked = model.state {
            items.append(Item(title: "What is secure input?", action: .openSecureInputHelp, indented: true))
        }
        items.append(.separator)

        // ADR-015: whenever a transcript did not reach an app, offer it back.
        if let recovery = model.recovery, recovery.outcome != .inserted {
            items.append(Item(title: "Copy Last Transcript",
                              action: .copyLastTranscript(recovery.id)))
            items.append(Item(title: "“\(recovery.preview)”",
                              action: nil, isEnabled: false, indented: true))
            items.append(.separator)
        }

        // Hotkey reminder, plus tap health when something is wrong.
        items.append(Item(title: model.triggerInstruction, action: nil, isEnabled: false))
        if let warning = model.hotkeyHealthWarning {
            items.append(Item(title: warning, action: nil, isEnabled: false, indented: true))
        }
        items.append(.separator)

        // Mode
        items.append(Item(title: "Mode", action: nil, isEnabled: false))
        for mode in Preferences.ProcessingMode.allCases {
            items.append(Item(title: mode.title,
                              action: .setProcessingMode(mode),
                              isChecked: mode == model.processingMode,
                              indented: true))
        }
        items.append(.separator)

        // Language
        items.append(Item(title: "Language", action: nil, isEnabled: false))
        for locale in Preferences.DictationLocale.allCases {
            items.append(Item(title: locale.title,
                              action: .setLocale(locale),
                              isChecked: locale == model.locale,
                              indented: true))
        }
        items.append(.separator)

        // Permissions
        let needsAttention = model.permissions.filter(\.needsAttention)
        items.append(Item(title: needsAttention.isEmpty
                          ? "Permissions: all granted"
                          : "Permissions: \(needsAttention.count) needed",
                          action: nil, isEnabled: false))
        for row in model.permissions {
            items.append(Item(title: row.title,
                              action: row.needsAttention ? .grantPermission(row.permission) : nil,
                              isEnabled: row.needsAttention,
                              indented: true))
        }
        if !needsAttention.isEmpty {
            items.append(Item(title: "Request Permissions…", action: .grantAllPermissions, indented: true))
        }
        items.append(.separator)

        items.append(Item(title: "Launch at Login",
                          action: .toggleLaunchAtLogin,
                          isChecked: model.launchAtLogin))
        items.append(Item(title: "Add Correction to Vocabulary…", action: .addVocabularyCorrection))
        items.append(Item(title: "Settings…", action: .openSettings))

        if model.isDebugBuild {
            items.append(.separator)
            items.append(Item(title: "Debug", action: nil, isEnabled: false))
            for summary in [model.hotkeyDebugSummary, model.captureDebugSummary,
                            model.speechDebugSummary].compactMap({ $0 }) {
                items.append(Item(title: summary, action: nil, isEnabled: false, indented: true))
            }
            for name in ["idle", "listening", "transcribing", "processing",
                         "inserting", "blocked", "failed"] {
                items.append(Item(title: "Force state: \(name)",
                                  action: .debugForceState(name), indented: true))
            }
            items.append(Item(title: "Record fake transcript",
                              action: .debugForceState("transcript"), indented: true))
        }

        items.append(.separator)
        items.append(Item(title: "Quit Whispering Flow", action: .quit))
        return items
    }
}
