import CoreGraphics
import Foundation

/// Where the HUD pill goes, given where the text cursor is.
///
/// Pure geometry so it is testable without a screen. Two coordinate systems are
/// in play: Accessibility reports rectangles with the origin at the **top-left
/// of the primary display** and y growing downward; AppKit windows use the
/// **bottom-left** origin with y growing upward. Getting that conversion wrong
/// puts the pill on the opposite side of the screen, so it is one tested function.
enum HUDPlacement {

    /// What was found under the cursor, in AppKit (bottom-left origin) coordinates.
    struct Anchor: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            /// The text insertion point (or the character next to it).
            case caret
            /// Only the focused element's frame was available.
            case element
        }
        var rect: CGRect
        var kind: Kind
    }

    /// Distance between the pill and the text it sits next to.
    static let gap: CGFloat = 10
    static let screenMargin: CGFloat = 8
    /// An element taller than this (a whole document editor) is not a useful
    /// thing to hang the pill under.
    static let smallElementHeight: CGFloat = 120

    /// AX rect (top-left origin) → AppKit rect (bottom-left origin).
    static func appKitRect(fromAX rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX,
               y: primaryScreenHeight - rect.maxY,
               width: rect.width,
               height: rect.height)
    }

    /// A rect worth trusting: finite, on-screen-ish, and not the all-zero rect
    /// many apps return when they do not implement the query.
    static func isUsable(_ rect: CGRect) -> Bool {
        guard rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.size.width.isFinite, rect.size.height.isFinite else { return false }
        guard rect.height > 0, rect.width >= 0 else { return false }
        return !(rect.origin == .zero && rect.size == .zero)
    }

    /// Bottom-left origin for the pill's window.
    static func origin(for anchor: Anchor?, size: CGSize, screen: CGRect) -> CGPoint {
        guard let anchor else { return bottomCentre(size: size, screen: screen) }

        let rect = anchor.rect
        var x = rect.midX - size.width / 2
        var y: CGFloat

        switch anchor.kind {
        case .caret:
            y = rect.minY - size.height - gap
            if y < screen.minY + screenMargin {
                y = rect.maxY + gap                      // no room below: go above
            }
        case .element where rect.height <= smallElementHeight:
            y = rect.minY - size.height - gap
            if y < screen.minY + screenMargin {
                y = rect.maxY + gap
            }
        case .element:
            // A big editor with no caret information: sit inside its bottom edge.
            y = rect.minY + gap
        }

        x = min(max(x, screen.minX + screenMargin), screen.maxX - size.width - screenMargin)
        y = min(max(y, screen.minY + screenMargin), screen.maxY - size.height - screenMargin)
        return CGPoint(x: x, y: y)
    }

    static func bottomCentre(size: CGSize, screen: CGRect) -> CGPoint {
        CGPoint(x: screen.midX - size.width / 2, y: screen.minY + 28)
    }
}
