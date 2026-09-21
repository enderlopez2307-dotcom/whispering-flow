import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

/// One way of getting text into the focused element.
///
/// Each strategy reports what actually happened rather than what it attempted.
/// That distinction is the whole lesson of the Safari address-bar failure: a
/// posted keystroke is not evidence of delivery.
protocol InsertionStrategy: Sendable {
    var name: String { get }
    /// Whether this strategy is worth trying against this target at all.
    func canAttempt(_ target: FocusedTarget) -> Bool
    @MainActor func insert(_ text: String, into target: FocusedTarget) async -> InsertionOutcome
}

// MARK: - Accessibility

/// Sets the focused element's value directly.
///
/// The clean path: atomic, no clipboard mutation, and it **reports failure**
/// when the element will not take a value — which is precisely what pasting
/// cannot do. It fails on Electron and many web views, which is why it is a
/// link in a chain rather than the whole answer.
struct AccessibilityInserter: InsertionStrategy {
    let name = "accessibility"

    func canAttempt(_ target: FocusedTarget) -> Bool {
        if case .editableText = target.confidence { return true }
        return false
    }

    @MainActor
    func insert(_ text: String, into target: FocusedTarget) async -> InsertionOutcome {
        guard let element = FocusedAppProbe.focusedElementForInsertion() else {
            return .failed(reason: "no focused element")
        }
        // These calls run on the main actor, and so does the hotkey tap. Without
        // a bound a hung target app would freeze this one for the system default
        // of several seconds.
        AXUIElementSetMessagingTimeout(element, 0.5)

        // **Set the selected text, never the whole value.**
        //
        // An earlier version read `AXValue`, spliced our text in at the caret
        // and wrote the result back. In Electron and web views `AXValue`
        // is not the field's editable content — it returns the whole visible
        // buffer including placeholder and hint text. Writing that back
        // materialised the hints as real text and duplicated the utterance:
        // VS Code produced "Testing dictation in VS Code. ⌘ Esc to focus or
        // unfocus Claude", and Codex typed the sentence twice plus "Do
        // anything" — none of which the user said.
        //
        // `AXSelectedText` is the correct API: it replaces the selection, or
        // inserts at the caret when the selection is empty, and touches nothing
        // else. Where it is not settable this strategy declines and the chain
        // falls through to pasting.
        var settable = DarwinBoolean(false)
        let probe = AXUIElementIsAttributeSettable(
            element, kAXSelectedTextAttribute as CFString, &settable)
        guard probe == .success, settable.boolValue else {
            return .failed(reason: "element does not accept selected-text insertion")
        }

        let status = AXUIElementSetAttributeValue(
            element, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
        guard status == .success else {
            return .failed(reason: "element refused the text (AX \(status.rawValue))")
        }

        // Verify rather than assume — the step the Phase 2 spike lacked. Some
        // elements accept the write and discard it.
        var readBack: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element, kAXValueAttribute as CFString, &readBack) == .success,
           let value = readBack as? String, !value.isEmpty {
            guard value.contains(text.trimmingCharacters(in: .whitespaces)) else {
                return .failed(reason: "text did not stick after writing")
            }
        }
        return .inserted(strategy: name)
    }
}

// MARK: - Clipboard paste

/// Writes to the pasteboard and posts ⌘V.
///
/// Works essentially anywhere a human can paste, which is the actual target
/// matrix. It cannot verify delivery, so it only runs after the focus probe has
/// already accepted the destination.
struct ClipboardPasteInserter: InsertionStrategy {
    let name = "clipboard"

    func canAttempt(_ target: FocusedTarget) -> Bool { target.allowsInsertion }

    @MainActor
    func insert(_ text: String, into target: FocusedTarget) async -> InsertionOutcome {
        if IsSecureEventInputEnabled() {
            return .refused(reason: "Secure input is active, so the system blocks pasting.")
        }
        let pasteboard = NSPasteboard.general

        // 1. Remember what the user had, across every type they had it in.
        let saved = pasteboard.pasteboardItems?.compactMap { item -> [NSPasteboard.PasteboardType: Data] in
            var contents: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { contents[type] = data }
            }
            return contents
        } ?? []

        // 2. Write ours and remember the change count it produced.
        let ourChangeCount = Self.writeTransient(text, to: pasteboard)

        // 3. Paste.
        guard postCommandV() else {
            restore(saved, ifChangeCountIsStill: ourChangeCount)
            return .failed(reason: "could not post the paste keystroke")
        }

        // Give the target time to actually read the pasteboard before we take
        // it away again. Too short and the paste gets the restored contents.
        try? await Task.sleep(for: .milliseconds(120))

        // 4. Restore only if nothing else touched the pasteboard meanwhile.
        //    If the user copied something during processing, theirs wins —
        //    overwriting it would destroy work we were never asked to touch.
        restore(saved, ifChangeCountIsStill: ourChangeCount)
        return .inserted(strategy: name)
    }

    /// Markers from the nspasteboard.org convention. Clipboard managers that
    /// follow it skip an item carrying them, so dictated text (which may be a
    /// password or a private message) is not recorded in a clipboard history.
    /// Apple does not document Universal Clipboard honouring them, so the honest
    /// claim is "not kept by clipboard managers", not "never synced"; the text is
    /// on the pasteboard for about 120 ms.
    static let transientTypes: [NSPasteboard.PasteboardType] = [
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
        NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
        NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"),
    ]

    /// Replace the pasteboard's contents with `text`, marked transient. Returns
    /// the change count this write produced.
    @MainActor
    @discardableResult
    static func writeTransient(_ text: String, to pasteboard: NSPasteboard) -> Int {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        for type in transientTypes { item.setData(Data(), forType: type) }
        pasteboard.writeObjects([item])
        return pasteboard.changeCount
    }

    @MainActor
    private func restore(_ saved: [[NSPasteboard.PasteboardType: Data]],
                         ifChangeCountIsStill expected: Int) {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount == expected else {
            Log.insertion.info("pasteboard changed during insertion — leaving the user's contents alone")
            return
        }
        pasteboard.clearContents()
        guard !saved.isEmpty else { return }
        let items = saved.map { contents -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in contents { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(items)
    }

    /// ⌘V through a private HID event source, so it is not intercepted by our
    /// own event tap and does not inherit stray modifiers the user is holding.
    @MainActor
    private func postCommandV() -> Bool {
        guard let source = CGEventSource(stateID: .privateState) else { return false }
        let v = CGKeyCode(kVK_ANSI_V)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false)
        else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
        return true
    }
}

// MARK: - Unicode typing

/// Types the text as synthesised key events carrying Unicode directly.
///
/// Last resort: visible, slow for long text, and no faster than paste. It earns
/// its place only where the pasteboard is unavailable or the target ignores
/// ⌘V — and it never runs for long transcripts, where the typing would be
/// slower than the user could read.
struct UnicodeKeystrokeInserter: InsertionStrategy {
    let name = "unicode-typing"

    /// Above this the visible per-character typing is worse than a clear error.
    static let maximumLength = 400

    func canAttempt(_ target: FocusedTarget) -> Bool { target.allowsInsertion }

    @MainActor
    func insert(_ text: String, into target: FocusedTarget) async -> InsertionOutcome {
        guard text.count <= Self.maximumLength else {
            return .failed(reason: "too long to type (\(text.count) characters)")
        }
        if IsSecureEventInputEnabled() {
            return .refused(reason: "Secure input is active, so synthetic typing is blocked.")
        }
        guard let source = CGEventSource(stateID: .privateState) else {
            return .failed(reason: "no event source")
        }

        // UTF-16 so accented characters and emoji survive intact.
        for chunk in Array(text.utf16).chunked(into: 20) {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { return .failed(reason: "could not synthesise a key event") }
            var buffer = chunk
            down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: &buffer)
            up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: &buffer)
            down.post(tap: .cgAnnotatedSessionEventTap)
            up.post(tap: .cgAnnotatedSessionEventTap)
            try? await Task.sleep(for: .milliseconds(4))
        }
        return .inserted(strategy: name)
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
