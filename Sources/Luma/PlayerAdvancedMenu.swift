import SwiftUI
import AppKit

/// Snapshot menu content when opening. Playback observations must not rebuild a tracking menu.
@MainActor indirect enum PlayerMenuEntry {
    case heading(String)
    case separator
    case action(String, selected: Bool = false, enabled: Bool = true, key: String = "", () -> Void)
    case submenu(String, [PlayerMenuEntry])
}

struct PlayerAdvancedMenu: NSViewRepresentable {
    let entries: [PlayerMenuEntry]
    let interaction: (Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        button.contentTintColor = .white
        button.appearance = NSAppearance(named: .darkAqua)
        button.preferredEdge = .maxY
        (button.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        button.toolTip = "高级选项"
        button.setAccessibilityLabel("高级选项")
        let menu = NSMenu(); menu.autoenablesItems = false
        menu.addItem(Coordinator.iconItem())
        menu.delegate = context.coordinator
        button.menu = menu
        return button
    }
    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.entries = entries
        context.coordinator.interaction = interaction
    }
    @MainActor final class Coordinator: NSObject, NSMenuDelegate {
        var entries: [PlayerMenuEntry] = []
        var interaction: (Bool) -> Void = { _ in }
        private var actions: [Int: () -> Void] = [:]
        static func iconItem() -> NSMenuItem {
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "gearshape.fill", accessibilityDescription: "高级选项")
            return item
        }
        func menuNeedsUpdate(_ menu: NSMenu) {
            actions.removeAll(keepingCapacity: true)
            let snapshot = makeMenu(entries)
            menu.removeAllItems(); menu.addItem(Self.iconItem())
            for item in snapshot.items { snapshot.removeItem(item); menu.addItem(item) }
        }
        func menuWillOpen(_ menu: NSMenu) { interaction(true) }
        func menuDidClose(_ menu: NSMenu) { interaction(false) }
        private func makeMenu(_ entries: [PlayerMenuEntry]) -> NSMenu {
            let menu = NSMenu(); menu.autoenablesItems = false
            for entry in entries {
                switch entry {
                case .heading(let title):
                    let item = NSMenuItem(title: title, action: nil, keyEquivalent: ""); item.isEnabled = false; menu.addItem(item)
                case .separator: menu.addItem(.separator())
                case .submenu(let title, let children):
                    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                    item.submenu = makeMenu(children); menu.addItem(item)
                case .action(let title, let selected, let enabled, let key, let action):
                    let item = NSMenuItem(title: title, action: #selector(select(_:)), keyEquivalent: key)
                    item.tag = actions.count; actions[item.tag] = action
                    item.target = self; item.state = selected ? .on : .off; item.isEnabled = enabled
                    if !key.isEmpty { item.keyEquivalentModifierMask = .command }
                    menu.addItem(item)
                }
            }
            return menu
        }
        @objc private func select(_ item: NSMenuItem) {
            guard let action = actions[item.tag] else { return }
            // Present sheets and file panels only after native menu tracking has finished.
            Task { @MainActor in action() }
        }
    }
}
