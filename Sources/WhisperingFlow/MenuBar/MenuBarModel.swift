import Foundation
import HotkeyGestureCore

/// Everything the menu needs, as plain data.
///
/// The builder is a pure function of this, so every menu state can be asserted
/// in a unit test without a status item, a run loop, or a live app.
struct MenuBarModel: Equatable, Sendable {

    struct PermissionRow: Equatable, Sendable {
        let permission: Permission
        let status: PermissionStatus

        var title: String {
            "\(permission.rawValue): \(status.symbol.capitalized)"
        }

        var needsAttention: Bool { !status.isGranted }
    }

    struct RecoveryRow: Equatable, Sendable {
        let id: UUID
        let preview: String
        let outcome: RecoverableTranscript.Outcome
    }

    var state: MenuBarState
    var statusTitle: String
    var statusDetail: String?
    var hotkeyDescription: String
    var triggerMode: TriggerMode
    var handsFreeDoubleTap: Bool
    var processingMode: Preferences.ProcessingMode
    var locale: Preferences.DictationLocale
    var permissions: [PermissionRow]
    var recovery: RecoveryRow?
    var launchAtLogin: Bool
    var isDebugBuild: Bool
    /// Nil when the tap is healthy. Non-nil text is shown in the menu, because a
    /// silent tap otherwise looks like a broken hotkey implementation.
    var hotkeyHealthWarning: String?
    /// What processing did to the last dictation, when that is worth knowing.
    var processingNotice: String?
    /// Debug-only readout of tap health and measured latency. Numbers only.
    var hotkeyDebugSummary: String?
    /// Debug-only capture readout: formats, latencies, frame counts. No audio.
    var captureDebugSummary: String?
    /// Debug-only recognition readout: format, timings, counts. No transcript text.
    var speechDebugSummary: String?

    static func make(session: SessionState,
                     preferences: Preferences,
                     permissionStatuses: [Permission: PermissionStatus],
                     latestRecoverable: RecoverableTranscript?,
                     launchAtLogin: Bool,
                     isDebugBuild: Bool,
                     hotkeyHealth: HotkeyDiagnostics.Health = .working,
                     hotkeyHealthDetail: String = "",
                     hotkeyDebugSummary: String? = nil,
                     captureDebugSummary: String? = nil,
                     speechDebugSummary: String? = nil,
                     lastTrace: ProductionTextProcessor.Trace? = nil,
                     smartSkipUnseen: Bool = false) -> MenuBarModel {

        let title: String
        var detail: String?
        switch session {
        case .idle:
            title = "Ready"
        case .listening:
            title = "Listening…"
        case .transcribing:
            title = "Transcribing…"
        case .processing:
            title = "Cleaning up…"
        case .inserting:
            title = "Inserting…"
        case .blocked(let reason):
            title = reason.title
            detail = reason.detail
        case .failed(let reason):
            title = reason.title
            detail = reason.detail
        }

        var state = MenuBarState(session: session)
        if state == .idle, smartSkipUnseen { state = .smartSkipped }

        return MenuBarModel(
            state: state,
            statusTitle: title,
            statusDetail: detail,
            hotkeyDescription: preferences.hotkey.displayName,
            triggerMode: preferences.triggerMode,
            handsFreeDoubleTap: preferences.handsFreeDoubleTap,
            processingMode: preferences.processingMode,
            locale: preferences.locale,
            permissions: Permission.allCases.map {
                PermissionRow(permission: $0, status: permissionStatuses[$0] ?? .notDetermined)
            },
            recovery: latestRecoverable.map {
                RecoveryRow(id: $0.id, preview: Self.preview(of: $0.text), outcome: $0.outcome)
            },
            launchAtLogin: launchAtLogin,
            isDebugBuild: isDebugBuild,
            hotkeyHealthWarning: hotkeyHealth == .working ? nil : hotkeyHealthDetail,
            processingNotice: lastTrace.flatMap(Self.notice(for:)),
            hotkeyDebugSummary: isDebugBuild ? hotkeyDebugSummary : nil,
            captureDebugSummary: isDebugBuild ? captureDebugSummary : nil,
            speechDebugSummary: isDebugBuild ? speechDebugSummary : nil
        )
    }

    /// Nothing for Fast runs — that is the normal case and needs no comment.
    static func notice(for trace: ProductionTextProcessor.Trace) -> String? {
        guard trace.smartRequested else { return nil }
        if trace.smartFellBack {
            return "Smart cleanup skipped (\(trace.smartFallbackReason ?? "unknown reason")) — Fast text was inserted"
        }
        return "Last dictation: Smart cleanup applied (\(String(format: "%.1f", trace.smartMilliseconds / 1000)) s)"
    }

    /// How to actually trigger dictation, in the user's configured mode.
    ///
    /// This line said "Hold …" unconditionally until Phase 4, when a stored
    /// `toggle` preference made a correctly-working app look like it was
    /// dropping key-up events for three minutes of debugging. The instruction
    /// must follow the mode.
    var triggerInstruction: String {
        switch triggerMode {
        case .hold:
            handsFreeDoubleTap
                ? "Hold \(hotkeyDescription) to dictate, or double-tap to keep talking"
                : "Hold \(hotkeyDescription) to dictate"
        case .toggle:
            "Press \(hotkeyDescription) to start, press again to stop"
        }
    }

    /// Short preview for the menu. Deliberately truncated — the menu bar is not
    /// the place to display a paragraph, and long titles break the menu layout.
    static func preview(of text: String, limit: Int = 42) -> String {
        let collapsed = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit - 1)) + "…"
    }
}
