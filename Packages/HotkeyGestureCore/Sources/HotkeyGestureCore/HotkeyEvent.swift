import Foundation

/// An immutable snapshot of one keyboard event.
///
/// Deliberately a plain value type carrying no CoreGraphics types: the event-tap
/// callback builds one of these and hands it across, so all gesture logic can be
/// tested with zero system calls. It also keeps the tap callback allocation-free
/// and free of anything that could retain a reference to the raw event.
public struct HotkeyEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case keyDown
        case keyUp
        case flagsChanged
    }

    public var kind: Kind
    public var keyCode: UInt16
    public var modifiers: Modifiers
    public var isAutoRepeat: Bool
    /// Seconds on a monotonic clock. Injected rather than read, so hold-threshold
    /// behaviour is testable without sleeping.
    public var timestamp: Double

    public init(
        kind: Kind,
        keyCode: UInt16,
        modifiers: Modifiers,
        isAutoRepeat: Bool = false,
        timestamp: Double
    ) {
        self.kind = kind
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.isAutoRepeat = isAutoRepeat
        self.timestamp = timestamp
    }
}

/// Left/right-discriminated modifier set.
///
/// The discrimination is the whole reason this app needs a `CGEventTap` rather
/// than a Carbon hotkey (ADR-004): binding "Right Option" specifically is not
/// expressible in the simpler APIs.
public struct Modifiers: OptionSet, Sendable, Equatable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let leftCommand  = Modifiers(rawValue: 1 << 0)
    public static let rightCommand = Modifiers(rawValue: 1 << 1)
    public static let leftShift    = Modifiers(rawValue: 1 << 2)
    public static let rightShift   = Modifiers(rawValue: 1 << 3)
    public static let leftOption   = Modifiers(rawValue: 1 << 4)
    public static let rightOption  = Modifiers(rawValue: 1 << 5)
    public static let leftControl  = Modifiers(rawValue: 1 << 6)
    public static let rightControl = Modifiers(rawValue: 1 << 7)
    public static let function     = Modifiers(rawValue: 1 << 8)
    public static let capsLock     = Modifiers(rawValue: 1 << 9)
}
