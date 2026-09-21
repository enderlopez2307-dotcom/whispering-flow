import Foundation
import OSLog

/// Central logging.
///
/// **Redaction rule, enforced by convention and reviewed every phase: no
/// transcript text and no key codes are ever logged.** The event tap sees every
/// keystroke on the system, including passwords. Only modifier *names*, state
/// transitions and counts are safe to persist.
///
/// Everything here is `.public` on purpose — none of it is sensitive, and
/// OSLog redacts interpolations by default, which makes logs useless for
/// support if left unmarked.
enum Log {
    private static let subsystem = "com.whisperingflow.dictation"

    static let app        = Logger(subsystem: subsystem, category: "app")
    static let permission = Logger(subsystem: subsystem, category: "permission")
    static let settings   = Logger(subsystem: subsystem, category: "settings")
    static let menuBar    = Logger(subsystem: subsystem, category: "menubar")
    static let session    = Logger(subsystem: subsystem, category: "session")
    static let hotkey     = Logger(subsystem: subsystem, category: "hotkey")
    static let audio      = Logger(subsystem: subsystem, category: "audio")
    static let speech     = Logger(subsystem: subsystem, category: "speech")
    static let processing = Logger(subsystem: subsystem, category: "processing")
    static let insertion  = Logger(subsystem: subsystem, category: "insertion")
    static let recovery   = Logger(subsystem: subsystem, category: "recovery")
}
