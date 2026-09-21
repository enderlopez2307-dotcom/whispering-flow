import Foundation
import ServiceManagement

/// Login-item registration via `SMAppService`.
///
/// The system is the source of truth, not our preference: the user can remove a
/// login item in System Settings without the app being running, so the stored
/// flag is reconciled against `SMAppService.mainApp.status` at launch.
enum LaunchAtLoginController {

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled: "Enabled"
        case .notRegistered: "Not registered"
        case .notFound: "Not found"
        case .requiresApproval: "Requires approval in System Settings"
        @unknown default: "Unknown"
        }
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Result<Void, any Error> {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
            Log.app.info("launch at login -> \(enabled, privacy: .public)")
            return .success(())
        } catch {
            Log.app.error("launch at login failed: \(error.localizedDescription, privacy: .public)")
            return .failure(error)
        }
    }
}
