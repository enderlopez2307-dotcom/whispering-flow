import AppKit
import ApplicationServices
import Foundation

/// Finds the text cursor of the frontmost app through Accessibility, so the HUD
/// can sit next to the text instead of at the bottom of the screen.
///
/// Apps differ wildly here. Native text views answer everything; Chrome and
/// Electron often answer nothing until accessibility is switched on; some give
/// a zero rectangle. So it is a fallback chain — caret, then the character
/// beside it, then the whole element — and any failure just means the caller
/// uses the bottom of the screen. It only *positions a pill*: nothing here
/// affects where text is inserted.
///
/// Every AX call is bounded (`AXUIElementSetMessagingTimeout`) and the whole
/// lookup runs on a worker with a hard wait limit, for the same reason
/// `FocusedAppProbe` does: a busy target must not freeze the machine.
enum CaretLocator {

    /// Carries the answer across the worker boundary. See `FocusedAppProbe`.
    private final class ResultBox: @unchecked Sendable {
        var anchor: HUDPlacement.Anchor?
    }

    /// Nil when the app will not say. Never throws, never blocks longer than
    /// `timeout`.
    ///
    /// `@MainActor` because the two lines below it read AppKit state
    /// (`NSWorkspace`, `NSScreen`). A nonisolated `async` function runs on the
    /// cooperative pool even when it is awaited from the main actor — the trap
    /// that has already cost this project twice. It does not block the main
    /// actor: the AX work and the bounded wait both happen on worker queues,
    /// and the continuation only resumes once they are done.
    @MainActor
    static func locate(timeout: TimeInterval = 0.2) async -> HUDPlacement.Anchor? {
        let app = NSWorkspace.shared.frontmostApplication
        // Our own windows (Settings) are not somewhere text is being dictated.
        guard let pid = app?.processIdentifier,
              pid != ProcessInfo.processInfo.processIdentifier else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        guard primaryHeight > 0 else { return nil }

        return await withCheckedContinuation { continuation in
            let box = ResultBox()
            let semaphore = DispatchSemaphore(value: 0)

            DispatchQueue.global(qos: .userInitiated).async {
                box.anchor = lookup(pid: pid, primaryScreenHeight: primaryHeight)
                semaphore.signal()
            }
            // A second hop so the wait itself never occupies the main actor.
            DispatchQueue.global(qos: .userInitiated).async {
                if semaphore.wait(timeout: .now() + timeout) == .success {
                    continuation.resume(returning: box.anchor)
                } else {
                    Log.app.info("caret lookup timed out after \(Int(timeout * 1000), privacy: .public) ms")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - Lookup (runs on the worker)

    private static func lookup(pid: pid_t, primaryScreenHeight: CGFloat) -> HUDPlacement.Anchor? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.1)

        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.1)

        if let caret = caretRect(of: element) {
            return HUDPlacement.Anchor(
                rect: HUDPlacement.appKitRect(fromAX: caret, primaryScreenHeight: primaryScreenHeight),
                kind: .caret)
        }
        if let frame = elementFrame(of: element) {
            return HUDPlacement.Anchor(
                rect: HUDPlacement.appKitRect(fromAX: frame, primaryScreenHeight: primaryScreenHeight),
                kind: .element)
        }
        return nil
    }

    /// The caret, or failing that the glyph beside it. Many text views return
    /// an empty rectangle for a zero-length range, so try a one-character range
    /// before giving up.
    private static func caretRect(of element: AXUIElement) -> CGRect? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range), range.location >= 0 else { return nil }

        // Zero-length first (the true caret), then the character before it (use
        // its right edge), then the character after it.
        let attempts: [(CFRange, useTrailingEdge: Bool)] = [
            (CFRange(location: range.location, length: 0), false),
            (CFRange(location: max(0, range.location - 1), length: range.location > 0 ? 1 : 0), true),
            (CFRange(location: range.location, length: 1), false),
        ]
        for (attempt, trailing) in attempts where attempt.length > 0 || !trailing {
            guard let rect = bounds(of: attempt, in: element),
                  HUDPlacement.isUsable(rect) else { continue }
            if trailing {
                return CGRect(x: rect.maxX, y: rect.minY, width: 0, height: rect.height)
            }
            return rect
        }
        return nil
    }

    private static func bounds(of range: CFRange, in element: AXUIElement) -> CGRect? {
        var mutable = range
        guard let parameter = AXValueCreate(.cfRange, &mutable) else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, parameter, &out) == .success,
              let out, CFGetTypeID(out) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(out as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }

    private static func elementFrame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        let rect = CGRect(origin: origin, size: size)
        return HUDPlacement.isUsable(rect) && rect.width > 0 ? rect : nil
    }
}
