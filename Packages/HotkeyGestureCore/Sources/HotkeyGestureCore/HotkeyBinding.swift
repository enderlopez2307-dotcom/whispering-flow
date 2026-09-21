import Foundation

/// What the user chose to hold. Either a bare modifier (the ergonomic choice for
/// push-to-talk) or a regular key, optionally with required modifiers.
public enum HotkeyBinding: Sendable, Equatable, Hashable {
    case bareModifier(Modifiers)
    case key(keyCode: UInt16, required: Modifiers)

    /// Whether this event, on its own, satisfies the binding's "held" condition.
    public func isSatisfied(by event: HotkeyEvent) -> Bool {
        switch self {
        case .bareModifier(let modifier):
            return event.modifiers.contains(modifier)
        case .key(let keyCode, let required):
            return event.keyCode == keyCode && event.modifiers.isSuperset(of: required)
        }
    }

    /// Whether an event is *about* this binding at all. Used to ignore unrelated
    /// keystrokes cheaply, before any state machine work.
    public func isRelevant(to event: HotkeyEvent) -> Bool {
        switch self {
        case .bareModifier:
            return event.kind == .flagsChanged
        case .key(let keyCode, _):
            return event.keyCode == keyCode
        }
    }
}

public enum TriggerMode: String, Sendable, CaseIterable, Hashable {
    /// Hold to record, release to stop. The V1 default.
    case hold
    /// Press once to start, press again to stop.
    case toggle
}

extension Modifiers {
    /// Human-readable names, in a stable order.
    ///
    /// Left/right are spelled out because the distinction is the whole reason
    /// this app needs an event tap, and "⌘" alone would hide it from the user.
    public var displayNames: [String] {
        var names: [String] = []
        if contains(.leftControl)  { names.append("Left Control") }
        if contains(.rightControl) { names.append("Right Control") }
        if contains(.leftOption)   { names.append("Left Option") }
        if contains(.rightOption)  { names.append("Right Option") }
        if contains(.leftShift)    { names.append("Left Shift") }
        if contains(.rightShift)   { names.append("Right Shift") }
        if contains(.leftCommand)  { names.append("Left Command") }
        if contains(.rightCommand) { names.append("Right Command") }
        if contains(.function)     { names.append("Fn") }
        if contains(.capsLock)     { names.append("Caps Lock") }
        return names
    }

    public var symbols: String {
        var parts: [String] = []
        if contains(.leftControl) || contains(.rightControl) { parts.append("⌃") }
        if contains(.leftOption) || contains(.rightOption)   { parts.append("⌥") }
        if contains(.leftShift) || contains(.rightShift)     { parts.append("⇧") }
        if contains(.leftCommand) || contains(.rightCommand) { parts.append("⌘") }
        if contains(.function)                               { parts.append("fn") }
        return parts.joined()
    }
}

extension HotkeyBinding {
    /// What the settings window and menu show.
    public var displayName: String {
        switch self {
        case .bareModifier(let modifiers):
            let names = modifiers.displayNames
            return names.isEmpty ? "None" : names.joined(separator: " + ")
        case .key(let keyCode, let required):
            let prefix = required.displayNames.isEmpty
                ? "" : required.displayNames.joined(separator: " + ") + " + "
            return prefix + (Self.keyName(for: keyCode) ?? "Key \(keyCode)")
        }
    }

    /// Names for the keys we offer as bindings. Deliberately not a full keymap:
    /// only keys that make sense to hold for push-to-talk are listed.
    static func keyName(for keyCode: UInt16) -> String? {
        switch keyCode {
        case 96:  "F5"
        case 97:  "F6"
        case 98:  "F7"
        case 100: "F8"
        case 101: "F9"
        case 109: "F10"
        case 103: "F11"
        case 111: "F12"
        case 105: "F13"
        case 107: "F14"
        case 113: "F15"
        case 106: "F16"
        case 64:  "F17"
        case 79:  "F18"
        case 80:  "F19"
        case 53:  "Escape"
        default:  nil
        }
    }

    /// Bindings offered in settings.
    ///
    /// Restricted to keys that physically exist on the target keyboard: there is
    /// one Control (left), both Options, both Commands, and F1–F12. F13–F19 and
    /// Right Control were offered in Phase 3 and are gone — a shortcut list that
    /// includes keys the user cannot press is a support problem, not a feature.
    ///
    /// Right Option stays selectable but is not the default: on the Spanish
    /// layout it composes `ó`, `ñ` and friends (ADR-014). The F-key entries
    /// require "Use F1, F2, etc. as standard function keys" to be on — otherwise
    /// macOS turns them into brightness/volume events that never reach a
    /// keyboard tap.
    public static let selectable: [HotkeyBinding] = [
        .bareModifier(.rightCommand),
        .bareModifier(.rightOption),
        .bareModifier(.leftControl),
        .bareModifier(.function),
        .key(keyCode: 97, required: []),    // F6
        .key(keyCode: 98, required: []),    // F7
        .key(keyCode: 100, required: []),   // F8
        .key(keyCode: 101, required: []),   // F9
    ]
}
