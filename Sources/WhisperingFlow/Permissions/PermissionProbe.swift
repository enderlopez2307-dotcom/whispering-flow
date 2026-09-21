import AVFoundation
import ApplicationServices
import Foundation
import IOKit.hid

/// Reads the current state of the three required grants.
///
/// Read-only and prompt-free by default: `status(of:)` never triggers a TCC
/// dialog, so it is safe to poll and safe to run from a diagnostic command.
/// This is what the Phase 1 signing experiment (Q5) uses to decide whether TCC
/// grants survive a rebuild.
enum PermissionProbe {

    public static func status(of permission: Permission) -> PermissionStatus {
        switch permission {
        case .microphone:      microphoneStatus()
        case .accessibility:   accessibilityStatus()
        case .inputMonitoring: inputMonitoringStatus()
        }
    }

    public static func snapshot() -> [Permission: PermissionStatus] {
        Dictionary(uniqueKeysWithValues: Permission.allCases.map { ($0, status(of: $0)) })
    }

    public static var allGranted: Bool {
        Permission.allCases.allSatisfy { status(of: $0).isGranted }
    }

    // MARK: - Individual probes

    private static func microphoneStatus() -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:         .granted
        case .denied, .restricted: .denied
        case .notDetermined:      .notDetermined
        @unknown default:         .notDetermined
        }
    }

    /// `AXIsProcessTrusted()` reads the current grant without prompting.
    /// The prompting variant (`AXIsProcessTrustedWithOptions`) is deliberately
    /// not used here — prompting is an explicit user action, not a side effect
    /// of reading state.
    private static func accessibilityStatus() -> PermissionStatus {
        AXIsProcessTrusted() ? .granted : .denied
    }

    private static func inputMonitoringStatus() -> PermissionStatus {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: .granted
        case kIOHIDAccessTypeDenied:  .denied
        default:                      .notDetermined
        }
    }

    // MARK: - Prompting

    /// Ask for microphone access. This is the only grant macOS will show a real
    /// dialog for; the other two must be toggled by hand in System Settings.
    public static func requestMicrophoneAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Ask for Input Monitoring. macOS shows a dialog the first time and
    /// registers the app under Privacy & Security > Input Monitoring; after
    /// that the user must toggle it there by hand.
    @discardableResult
    public static func requestInputMonitoringAccess() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    /// Show the Accessibility prompt. Returns the trust state at call time.
    ///
    /// The key is spelled literally rather than via `kAXTrustedCheckOptionPrompt`:
    /// that symbol is imported as a mutable global, which is not concurrency-safe
    /// under Swift 6. The literal is the documented, stable value behind it.
    @discardableResult
    public static func promptForAccessibility() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
