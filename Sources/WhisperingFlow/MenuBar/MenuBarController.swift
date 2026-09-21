import AppKit
import Foundation

/// Owns the `NSStatusItem` and translates menu clicks into actions.
///
/// It renders `MenuBarModel` and nothing else — it holds no app state and never
/// talks to audio, speech or insertion. All decisions live in the coordinator.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {

    private let statusItem: NSStatusItem
    private var model: MenuBarModel
    private var actions: [ObjectIdentifier: MenuAction] = [:]

    var onAction: ((MenuAction) -> Void)?
    /// Called just before the menu opens, so permission state is fresh rather
    /// than up to one poll interval stale.
    var willOpenMenu: (() -> Void)?

    init(initialModel: MenuBarModel) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.model = initialModel
        super.init()

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        applyIcon()
        rebuildMenu()
        Log.menuBar.info("status item installed")
    }

    func update(model: MenuBarModel) {
        guard model != self.model else { return }
        let iconChanged = model.state != self.model.state
        self.model = model
        if iconChanged { applyIcon() }
        rebuildMenu()
    }

    // MARK: - Rendering

    private func applyIcon() {
        guard let button = statusItem.button else { return }
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        button.image = NSImage(systemSymbolName: model.state.symbolName,
                               accessibilityDescription: model.state.accessibilityLabel)?
            .withSymbolConfiguration(configuration)
        button.image?.isTemplate = true
        button.toolTip = model.statusDetail.map { "\(model.statusTitle) — \($0)" } ?? model.statusTitle
        Log.menuBar.info("icon -> \(self.model.state.symbolName, privacy: .public)")
    }

    private func rebuildMenu() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()
        actions.removeAll()
        for item in MenuBarMenuBuilder.items(for: model) {
            menu.addItem(makeItem(item))
        }
    }

    private func makeItem(_ item: MenuBarMenuBuilder.Item) -> NSMenuItem {
        if item.isSeparator { return .separator() }

        let menuItem = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
        menuItem.isEnabled = item.isEnabled && item.action != nil
        menuItem.state = item.isChecked ? .on : .off
        menuItem.indentationLevel = item.indented ? 1 : 0

        if let action = item.action, item.isEnabled {
            menuItem.target = self
            menuItem.action = #selector(handleMenuItem(_:))
            actions[ObjectIdentifier(menuItem)] = action
        }
        return menuItem
    }

    @objc private func handleMenuItem(_ sender: NSMenuItem) {
        guard let action = actions[ObjectIdentifier(sender)] else { return }
        onAction?(action)
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        willOpenMenu?()
    }
}
