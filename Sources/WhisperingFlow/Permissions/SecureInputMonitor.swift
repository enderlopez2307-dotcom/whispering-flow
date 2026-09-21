import AppKit
import Carbon.HIToolbox
import Foundation
import Observation

/// Watches whether any process is holding Secure Event Input.
///
/// While it is held, our event tap receives **nothing** and synthetic paste is
/// refused — with no error and no callback (ADR-005). This is the single most
/// confusing failure mode in this class of app, so it gets a first-class,
/// user-visible state rather than being reported as "the hotkey stopped working".
///
/// It is not hypothetical: during Phase 2.5 development a macOS authentication
/// dialog (`SecurityAgent`) held it for several minutes and silently disabled
/// the hotkey. Terminal's "Secure Keyboard Entry" does the same, and Terminal is
/// on the target app list.
@MainActor
@Observable
final class SecureInputMonitor {

    private(set) var isActive: Bool = IsSecureEventInputEnabled()

    /// The process currently holding it, when it can be determined. Best-effort:
    /// the lookup is not documented API, so a nil name is normal.
    private(set) var holderDescription: String?

    private var timer: Timer?
    private let interval: TimeInterval

    init(interval: TimeInterval = 2.0) {
        self.interval = interval
    }

    func start() {
        guard timer == nil else { return }
        refresh()
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = interval / 2   // let the system coalesce; this is not urgent
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let active = IsSecureEventInputEnabled()
        guard active != isActive else { return }
        isActive = active
        holderDescription = nil
        if active {
            // `ioreg` dumps the whole I/O registry, which takes long enough to
            // stall the main actor, and the hotkey tap runs on it. Look the
            // holder up off the main thread and fill it in when it arrives.
            Task.detached(priority: .utility) { [weak self] in
                let holder = Self.currentHolder()
                await MainActor.run {
                    guard let self, self.isActive else { return }
                    self.holderDescription = holder
                }
            }
        }
        Log.permission.info("secure input -> \(active ? "ACTIVE" : "clear", privacy: .public)")
    }

    /// Best-effort holder identification, for the explanation text.
    private nonisolated static func currentHolder() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        process.arguments = ["-l", "-w", "0"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8),
              let range = text.range(of: #""kCGSSessionSecureInputPID"=\d+"#, options: .regularExpression),
              let pid = Int32(text[range].split(separator: "=").last.map(String.init) ?? "")
        else { return nil }
        return NSRunningApplication(processIdentifier: pid)?.localizedName
    }
}
