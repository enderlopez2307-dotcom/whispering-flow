import AppKit
import Foundation
import Observation

/// Live view of the three grants the app cannot work without.
///
/// Polls rather than observes because macOS provides no change notification for
/// Accessibility or Input Monitoring. The interval is deliberately lazy and the
/// timer suspends once everything is granted, so the steady-state cost is zero.
@MainActor
@Observable
final class PermissionCenter {

    private(set) var statuses: [Permission: PermissionStatus] = [:]

    private var timer: Timer?
    private let activeInterval: TimeInterval
    private var onChange: (() -> Void)?

    var allGranted: Bool {
        Permission.allCases.allSatisfy { statuses[$0]?.isGranted == true }
    }

    var missing: [Permission] {
        Permission.allCases.filter { statuses[$0]?.isGranted != true }
    }

    /// `statuses` is injectable so the coordinator's readiness logic can be
    /// tested. A test process inherits the *terminal's* TCC grants, which are
    /// unrelated to the app's (TECH_RESEARCH §15.7), so reading the real ones
    /// would make these tests pass or fail based on the developer's machine.
    init(activeInterval: TimeInterval = 2.0,
         statuses: [Permission: PermissionStatus]? = nil) {
        self.activeInterval = activeInterval
        self.statuses = statuses ?? PermissionProbe.snapshot()
    }

    func start(onChange: @escaping () -> Void) {
        self.onChange = onChange
        guard timer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: activeInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = activeInterval / 2
        self.timer = timer
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Re-read every grant; notify only when something actually changed, so the
    /// menu is not rebuilt twice a second for nothing.
    func refresh() {
        let updated = PermissionProbe.snapshot()
        guard updated != statuses else { return }

        let changes = Permission.allCases.compactMap { permission -> String? in
            guard statuses[permission] != updated[permission] else { return nil }
            return "\(permission.rawValue)=\(updated[permission]?.rawValue ?? "?")"
        }
        statuses = updated
        Log.permission.info("changed: \(changes.joined(separator: " "), privacy: .public)")
        onChange?()
    }

    func status(of permission: Permission) -> PermissionStatus {
        statuses[permission] ?? .notDetermined
    }

    /// Open the System Settings pane that grants this permission.
    func revealSettings(for permission: Permission) {
        NSWorkspace.shared.open(permission.settingsURL)
    }

    /// Ask for whatever can actually be asked for. Microphone shows a real
    /// dialog; the other two only register the app in their System Settings
    /// list, where the user must toggle them by hand.
    func requestAll() {
        Task { @MainActor in
            _ = await PermissionProbe.requestMicrophoneAccess()
            _ = PermissionProbe.requestInputMonitoringAccess()
            _ = PermissionProbe.promptForAccessibility()
            refresh()
        }
    }
}
