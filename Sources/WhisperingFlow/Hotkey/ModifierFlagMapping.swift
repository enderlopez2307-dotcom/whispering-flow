import CoreGraphics
import HotkeyGestureCore

/// Translates `CGEventFlags` into the pure `Modifiers` set.
///
/// The device-dependent bits are what make left/right discrimination possible,
/// and they are the entire reason this app needs a `CGEventTap` rather than a
/// Carbon hotkey (ADR-004). Values are from
/// `IOKit/hidsystem/IOLLEvent.h` and were read from the SDK, not remembered —
/// the Phase 2 spike had Left and Right Command transposed in its diagnostics.
enum ModifierFlagMapping {

    // NX_DEVICE*KEYMASK, verified against MacOSX26.5.sdk.
    private static let leftControl:  UInt64 = 0x00000001
    private static let leftShift:    UInt64 = 0x00000002
    private static let rightShift:   UInt64 = 0x00000004
    private static let leftCommand:  UInt64 = 0x00000008
    private static let rightCommand: UInt64 = 0x00000010
    private static let leftOption:   UInt64 = 0x00000020
    private static let rightOption:  UInt64 = 0x00000040
    private static let rightControl: UInt64 = 0x00002000

    static func modifiers(from raw: UInt64) -> Modifiers {
        var modifiers: Modifiers = []
        if raw & leftControl  != 0 { modifiers.insert(.leftControl) }
        if raw & rightControl != 0 { modifiers.insert(.rightControl) }
        if raw & leftShift    != 0 { modifiers.insert(.leftShift) }
        if raw & rightShift   != 0 { modifiers.insert(.rightShift) }
        if raw & leftCommand  != 0 { modifiers.insert(.leftCommand) }
        if raw & rightCommand != 0 { modifiers.insert(.rightCommand) }
        if raw & leftOption   != 0 { modifiers.insert(.leftOption) }
        if raw & rightOption  != 0 { modifiers.insert(.rightOption) }
        if raw & UInt64(CGEventFlags.maskSecondaryFn.rawValue) != 0 { modifiers.insert(.function) }
        if raw & UInt64(CGEventFlags.maskAlphaShift.rawValue) != 0 { modifiers.insert(.capsLock) }
        return modifiers
    }
}
