import Foundation
import HotkeyGestureCore
import Observation

/// The single place that touches `UserDefaults`.
///
/// No other module reads or writes defaults directly, so persistence can be
/// swapped or stubbed without ripples, and a preference rename is one edit.
@MainActor
@Observable
final class SettingsStore {

    private enum Key {
        static let hotkeyKind = "hotkey.kind"
        static let hotkeyModifiers = "hotkey.modifiers"
        static let hotkeyKeyCode = "hotkey.keyCode"
        static let triggerMode = "hotkey.triggerMode"
        static let handsFree = "hotkey.handsFreeDoubleTap"
        static let processingMode = "processing.mode"
        static let locale = "dictation.locale"
        static let launchAtLogin = "app.launchAtLogin"
        static let feedbackSounds = "app.feedbackSounds"
        static let showHUD = "app.showListeningHUD"
        static let inputDeviceUID = "audio.inputDeviceUID"
        static let recordDiagnostics = "diagnostics.recordTranscripts"
    }

    private let defaults: UserDefaults

    /// Mutating this writes through immediately, so a crash cannot lose a setting.
    var preferences: Preferences {
        didSet {
            guard preferences != oldValue else { return }
            persist(preferences)
            Log.settings.info("preferences changed")
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.preferences = Self.load(from: defaults)
    }

    // MARK: - Load

    private static func load(from defaults: UserDefaults) -> Preferences {
        var preferences = Preferences.default

        if let kind = defaults.string(forKey: Key.hotkeyKind) {
            let modifiers = Modifiers(rawValue: UInt32(defaults.integer(forKey: Key.hotkeyModifiers)))
            switch kind {
            case "bareModifier":
                preferences.hotkey = .bareModifier(modifiers)
            case "key":
                preferences.hotkey = .key(keyCode: UInt16(defaults.integer(forKey: Key.hotkeyKeyCode)),
                                          required: modifiers)
            default:
                break
            }
        }
        if let raw = defaults.string(forKey: Key.triggerMode), let mode = TriggerMode(rawValue: raw) {
            preferences.triggerMode = mode
        }
        if defaults.object(forKey: Key.handsFree) != nil {
            preferences.handsFreeDoubleTap = defaults.bool(forKey: Key.handsFree)
        }
        if let raw = defaults.string(forKey: Key.processingMode),
           let mode = Preferences.ProcessingMode(rawValue: raw) {
            preferences.processingMode = mode
        }
        if let raw = defaults.string(forKey: Key.locale),
           let locale = Preferences.DictationLocale(rawValue: raw) {
            preferences.locale = locale
        }
        if defaults.object(forKey: Key.launchAtLogin) != nil {
            preferences.launchAtLogin = defaults.bool(forKey: Key.launchAtLogin)
        }
        if defaults.object(forKey: Key.feedbackSounds) != nil {
            preferences.playFeedbackSounds = defaults.bool(forKey: Key.feedbackSounds)
        }
        if defaults.object(forKey: Key.showHUD) != nil {
            preferences.showListeningHUD = defaults.bool(forKey: Key.showHUD)
        }
        preferences.inputDeviceUID = defaults.string(forKey: Key.inputDeviceUID)
        preferences.recordDiagnosticTranscripts = defaults.bool(forKey: Key.recordDiagnostics)
        return migrate(preferences)
    }

    /// Drop a stored binding that is no longer offered.
    ///
    /// Phase 3 offered F13–F19 and Right Control, which do not exist on this
    /// keyboard; a preference pointing at one of them produces an event tap that
    /// runs perfectly and can never fire. That failure is completely silent, so
    /// it is corrected at load rather than surfaced as a warning.
    static func migrate(_ preferences: Preferences) -> Preferences {
        guard !HotkeyBinding.selectable.contains(preferences.hotkey) else { return preferences }
        Log.settings.info("stored hotkey \(preferences.hotkey.displayName, privacy: .public) is no longer offered — resetting to \(Preferences.default.hotkey.displayName, privacy: .public)")
        var migrated = preferences
        migrated.hotkey = Preferences.default.hotkey
        return migrated
    }

    // MARK: - Save

    private func persist(_ preferences: Preferences) {
        switch preferences.hotkey {
        case .bareModifier(let modifiers):
            defaults.set("bareModifier", forKey: Key.hotkeyKind)
            defaults.set(Int(modifiers.rawValue), forKey: Key.hotkeyModifiers)
            defaults.removeObject(forKey: Key.hotkeyKeyCode)
        case .key(let keyCode, let required):
            defaults.set("key", forKey: Key.hotkeyKind)
            defaults.set(Int(required.rawValue), forKey: Key.hotkeyModifiers)
            defaults.set(Int(keyCode), forKey: Key.hotkeyKeyCode)
        }
        defaults.set(preferences.triggerMode.rawValue, forKey: Key.triggerMode)
        defaults.set(preferences.handsFreeDoubleTap, forKey: Key.handsFree)
        defaults.set(preferences.processingMode.rawValue, forKey: Key.processingMode)
        defaults.set(preferences.locale.rawValue, forKey: Key.locale)
        defaults.set(preferences.launchAtLogin, forKey: Key.launchAtLogin)
        defaults.set(preferences.playFeedbackSounds, forKey: Key.feedbackSounds)
        defaults.set(preferences.showListeningHUD, forKey: Key.showHUD)
        defaults.set(preferences.recordDiagnosticTranscripts, forKey: Key.recordDiagnostics)
        if let uid = preferences.inputDeviceUID {
            defaults.set(uid, forKey: Key.inputDeviceUID)
        } else {
            defaults.removeObject(forKey: Key.inputDeviceUID)
        }
    }

    /// Restore defaults. Used by tests and the settings window.
    func reset() {
        preferences = .default
    }
}
