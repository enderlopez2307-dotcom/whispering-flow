import Foundation
import HotkeyGestureCore

/// Everything the user can configure. A plain value type so it can be diffed,
/// defaulted, and tested without touching `UserDefaults`.
struct Preferences: Sendable, Equatable {

    /// Fast is the default and never runs a language model (ADR-014).
    enum ProcessingMode: String, Sendable, CaseIterable {
        case fast
        case smart

        var title: String {
            switch self {
            case .fast: "Fast"
            case .smart: "Smart"
            }
        }

        var detail: String {
            switch self {
            case .fast: "Vocabulary and deterministic cleanup only. ~100 ms."
            case .smart: "Adds on-device Apple Intelligence cleanup. Slower, and it can rephrase."
            }
        }
    }

    enum DictationLocale: String, Sendable, CaseIterable {
        case englishUS = "en-US"
        case spanishES = "es-ES"

        var title: String {
            switch self {
            case .englishUS: "English (US)"
            case .spanishES: "Spanish (Spain)"
            }
        }
    }

    var hotkey: HotkeyBinding
    var triggerMode: TriggerMode
    /// Double-tap the hotkey to keep dictating without holding it. Additive to
    /// hold-to-talk, which stays the default trigger (ADR-016, ADR-025).
    var handsFreeDoubleTap: Bool = true
    var processingMode: ProcessingMode
    var locale: DictationLocale
    var launchAtLogin: Bool
    var playFeedbackSounds: Bool
    /// The floating waveform pill shown while the microphone is open. On by
    /// default: in hands-free mode it is the only sign the mic is live.
    var showListeningHUD: Bool = true
    var inputDeviceUID: String?
    /// Write each dictation's engine, intermediate and final text to a local
    /// file for diagnosing quality problems. Off by default: it is a plaintext
    /// record of everything the user says.
    var recordDiagnosticTranscripts: Bool = false

    /// Right Command, deliberately.
    ///
    /// Right Option was the Phase 2 spike default and is a poor production
    /// choice for this user: it is how `ó` and `ñ` are typed, so it collides
    /// with bilingual writing (ADR-014).
    static let `default` = Preferences(
        hotkey: .bareModifier(.rightCommand),
        triggerMode: .hold,
        processingMode: .fast,
        locale: .englishUS,
        launchAtLogin: false,
        playFeedbackSounds: true,
        inputDeviceUID: nil
    )
}
