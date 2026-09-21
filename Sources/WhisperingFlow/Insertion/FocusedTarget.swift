import AppKit
import ApplicationServices
import Foundation

/// Where dictated text is about to go.
///
/// This type exists because of one failure. The Phase 2 spike pasted into
/// Safari, reported success, and put the sentence **in the address bar**
/// (TECH_RESEARCH §15). Posting ⌘V is fire-and-forget: it proves a keystroke
/// was delivered, never that text reached the intended destination.
///
/// So the destination is inspected before anything is delivered, and again at
/// delivery time to confirm it has not changed underneath us.
struct FocusedTarget: Sendable, Equatable {

    /// How much we trust that inserting here is what the user meant.
    enum Confidence: Sendable, Equatable {
        /// A text-entry element we identified positively.
        case editableText
        /// A secure field. **Never** insert.
        case secureField
        /// Identified, but not somewhere text belongs — a button, a list row.
        case notEditable(role: String)
        /// Inside window chrome rather than content: an address bar, a search
        /// field in a toolbar, a find bar.
        case windowChrome(detail: String)
        /// The app answers no accessibility queries at all. Common and normal
        /// for Electron and some web views; paste is still the right move
        /// because the app was frontmost and focused when dictation started.
        case opaque
        /// The frontmost app changed since dictation began.
        case appChanged(from: String, to: String)
    }

    var bundleIdentifier: String?
    var applicationName: String?
    var processIdentifier: pid_t
    var role: String?
    var subrole: String?
    var confidence: Confidence

    var allowsInsertion: Bool {
        switch confidence {
        case .editableText, .opaque: true
        case .secureField, .notEditable, .windowChrome, .appChanged: false
        }
    }

    /// What the user is told when insertion is declined. Concrete, because
    /// "insertion failed" tells them nothing about what to do next.
    var refusalReason: String? {
        switch confidence {
        case .editableText, .opaque:
            nil
        case .secureField:
            "The cursor is in a password or secure field. Dictation never types into those."
        case .notEditable(let role):
            "The cursor is not in a text field (\(Self.friendlyRole(role))). "
            + "Click where you want the text and use Copy Last Transcript."
        case .windowChrome(let detail):
            "The cursor is in \(detail), not in the page or document. "
            + "Click where you want the text and use Copy Last Transcript."
        case .appChanged(let from, let to):
            "You switched from \(from) to \(to) while dictating, so nothing was inserted."
        }
    }

    static func friendlyRole(_ role: String) -> String {
        switch role {
        case "AXButton": "a button"
        case "AXStaticText": "read-only text"
        case "AXList", "AXTable", "AXOutline": "a list"
        case "AXWebArea": "a web page with no text field focused"
        case "AXGroup": "a container"
        case "AXUnknown", "": "an unknown element"
        default: role.hasPrefix("AX") ? String(role.dropFirst(2)).lowercased() : role
        }
    }
}

/// Reads the focused element through the Accessibility API.
///
/// Every call is bounded by a timeout. An unresponsive target can block an AX
/// query indefinitely, and a dictation app that freezes the whole machine
/// because Slack is busy is worse than one that declines to insert.
enum FocusedAppProbe {

    /// AX subroles that must never receive dictated text.
    static let secureSubroles: Set<String> = ["AXSecureTextField"]

    /// Roles that accept typed text.
    static let editableRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField",
    ]

    /// Subroles that are emphatically not a document. Kept, but **not relied
    /// on**: on macOS 26 Safari's address bar reports no subrole at all, so a
    /// blacklist of subroles let a dictated sentence straight into it during
    /// milestone testing — the same failure as the Phase 2 spike.
    static let rejectedSubroles: Set<String> = ["AXURIField", "AXSearchField"]

    /// Browsers, where "the cursor is in a text field" is not nearly enough:
    /// the address bar is a text field too.
    static let browserBundles: Set<String> = [
        "com.apple.Safari", "com.google.Chrome", "com.google.Chrome.canary",
        "org.mozilla.firefox", "com.microsoft.edgemac", "com.brave.Browser",
        "company.thebrowser.Browser", "com.operasoftware.Opera",
    ]

    /// Ancestor roles that mean "window chrome, not content".
    static let chromeAncestorRoles: Set<String> = ["AXToolbar", "AXSheet", "AXPopover"]

    /// How far up the accessibility tree to look. Deep enough to leave a web
    /// view, shallow enough to stay fast.
    static let ancestorDepth = 10

    static func current(timeout: TimeInterval = 0.25) -> FocusedTarget {
        let app = NSWorkspace.shared.frontmostApplication
        let pid = app?.processIdentifier ?? 0

        var target = FocusedTarget(bundleIdentifier: app?.bundleIdentifier,
                                   applicationName: app?.localizedName,
                                   processIdentifier: pid,
                                   role: nil,
                                   subrole: nil,
                                   confidence: .opaque)
        guard pid != 0 else { return target }

        guard let element = focusedElement(pid: pid, timeout: timeout) else {
            // No AX answer at all. Electron apps and some web views behave this
            // way normally, so this is not a failure — paste still works.
            return target
        }

        let role = string(of: element, attribute: kAXRoleAttribute as String)
        let subrole = string(of: element, attribute: kAXSubroleAttribute as String)
        target.role = role
        target.subrole = subrole

        if let subrole, secureSubroles.contains(subrole) {
            target.confidence = .secureField
            return target
        }
        if let subrole, rejectedSubroles.contains(subrole) {
            target.confidence = .windowChrome(detail: "the address or search bar")
            return target
        }

        // Structure, not labels. Walking the ancestor chain answers "is this
        // window chrome or is this content?" without depending on an app
        // reporting a helpful subrole — which Safari does not.
        let ancestry = ancestorRoles(of: element, limit: ancestorDepth)
        if let chrome = ancestry.first(where: { chromeAncestorRoles.contains($0) }) {
            target.confidence = .windowChrome(
                detail: chrome == "AXToolbar" ? "the browser toolbar or address bar"
                                              : "a dialog or popover")
            return target
        }
        // A "require an AXWebArea ancestor" rule was tried here and removed:
        // Chrome does not expose one without `AXManualAccessibility`, so it
        // refused *every* Chrome insertion — Gmail, WhatsApp Web and ChatGPT
        // all failed with a warning and no text. The toolbar-ancestor check
        // above is what actually caught Safari's address bar, and it is enough.
        guard let role else {
            target.confidence = .opaque
            return target
        }
        if editableRoles.contains(role) {
            target.confidence = .editableText
        } else if role == "AXWebArea" || role == "AXGroup" || role == "AXScrollArea" {
            // A web area *containing* an editable region is normal for Gmail
            // and ChatGPT. AX cannot always see into it, so this is treated as
            // opaque rather than refused — the app was focused deliberately.
            target.confidence = .opaque
        } else {
            target.confidence = .notEditable(role: role)
        }
        return target
    }

    /// Confirm the destination is still the one dictation started against.
    static func verify(_ original: FocusedTarget, timeout: TimeInterval = 0.25) -> FocusedTarget {
        var now = current(timeout: timeout)
        if let before = original.bundleIdentifier, let after = now.bundleIdentifier,
           before != after {
            now.confidence = .appChanged(from: original.applicationName ?? before,
                                         to: now.applicationName ?? after)
        }
        return now
    }

    // MARK: - AX plumbing

    /// Carries an `AXUIElement` across the worker boundary.
    ///
    /// `AXUIElement` is a CoreFoundation type and not `Sendable`. It is
    /// genuinely safe here — the box is written once on the worker and read
    /// once on the caller, with a semaphore between them — but the compiler
    /// cannot see that, and silencing it with `@preconcurrency` would suppress
    /// real diagnostics across the whole module.
    private final class ElementBox: @unchecked Sendable {
        var element: AXUIElement?
    }

    /// AX calls are synchronous and can hang against an unresponsive app.
    /// Run on a worker and give up rather than freezing the machine.
    private static func focusedElement(pid: pid_t, timeout: TimeInterval) -> AXUIElement? {
        let box = ElementBox()
        let semaphore = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .userInitiated).async {
            // Built inside the closure so no non-Sendable value is captured.
            let application = AXUIElementCreateApplication(pid)
            var value: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(
                application, kAXFocusedUIElementAttribute as CFString, &value)
            if status == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                box.element = (value as! AXUIElement)
            }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            // The worker may still be blocked; the box is simply abandoned.
            Log.insertion.info("focus probe timed out after \(Int(timeout * 1000), privacy: .public) ms")
            return nil
        }
        return box.element
    }

    private static func string(of element: AXUIElement, attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    /// The text currently selected in the frontmost app, if it exposes one.
    /// Read while that app is still frontmost — before Settings activates us.
    static func selectedText(timeout: TimeInterval = 0.25) -> String? {
        guard let element = focusedElementForInsertion(timeout: timeout) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextAttribute as CFString, &value) == .success,
              let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // A whole paragraph is not a vocabulary entry.
        return (1...60).contains(trimmed.count) ? trimmed : nil
    }

    /// Roles of the focused element's ancestors, nearest first.
    static func ancestorRoles(of element: AXUIElement, limit: Int) -> [String] {
        var roles: [String] = []
        var current = element
        for _ in 0..<limit {
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                current, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID()
            else { break }
            let next = parent as! AXUIElement
            if let role = string(of: next, attribute: kAXRoleAttribute as String) {
                roles.append(role)
            }
            current = next
        }
        return roles
    }

    /// Every attribute the focused element exposes, for diagnosing why a
    /// target was accepted or refused.
    static func debugAttributes() -> [(String, String)] {
        guard let element = focusedElementForInsertion(timeout: 1.0) else {
            return [("(no element)", "the app answered no accessibility query")]
        }
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(element, &names) == .success,
              let list = names as? [String] else { return [("(no attributes)", "")] }

        var rows: [(String, String)] = []
        for name in list.sorted() {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
                  let value else { continue }
            var settable = DarwinBoolean(false)
            AXUIElementIsAttributeSettable(element, name as CFString, &settable)
            let description = String(describing: value).prefix(60)
            rows.append((name + (settable.boolValue ? " (settable)" : ""), String(description)))
        }
        return rows
    }

    /// The focused element, for the AX inserter. Same timeout discipline.
    static func focusedElementForInsertion(timeout: TimeInterval = 0.25) -> AXUIElement? {
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        guard pid != 0 else { return nil }
        return focusedElement(pid: pid, timeout: timeout)
    }
}
