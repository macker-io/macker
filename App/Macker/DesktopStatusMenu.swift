import AppKit
import Observation

final class DesktopStatusMenu: NSObject, NSMenuDelegate {
    private let model: DesktopModel
    private let item = NSStatusBar.system.statusItem(withLength: 24)
    private let menu = NSMenu()
    var openManager: () -> Void

    init(model: DesktopModel, openManager: @escaping () -> Void) {
        self.model = model
        self.openManager = openManager
        super.init()

        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        item.button?.imagePosition = .imageOnly
        updateIcon()
        menuNeedsUpdate(menu)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        add("Open Macker", action: #selector(showManager(_:)))
        menu.addItem(.separator())
        add(model.connection.title)
        if model.isBuilding { add("Building…") }
        if model.connection.isConnected || model.activity != nil {
            add("Running Containers: \(model.menuRunningCount)")
            for container in model.runningContainers.prefix(6) {
                let entry = add(container.name, action: #selector(showManager(_:)))
                entry.representedObject = container.id
            }
        }
        add("Refresh Resources", action: #selector(refresh), enabled: !model.isRefreshing)
        menu.addItem(.separator())
        add("Quit Macker", action: #selector(quit), keyEquivalent: "q")
    }

    private func updateIcon() {
        withObservationTracking {
            item.button?.image = NSImage(named: model.fishAssetName)
            let title = model.isBuilding ? "\(model.connection.title), Building" : model.connection.title
            item.button?.setAccessibilityLabel(title)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.updateIcon() }
        }
    }

    @discardableResult
    private func add(
        _ title: String, action: Selector? = nil, enabled: Bool = true, keyEquivalent: String = ""
    ) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        entry.target = self
        entry.isEnabled = action != nil && enabled
        menu.addItem(entry)
        return entry
    }

    @objc private func showManager(_ sender: NSMenuItem) {
        if let containerID = sender.representedObject as? String {
            model.showContainer(containerID)
        }
        openManager()
        NSApp.activate()
        model.refresh()
    }

    @objc private func refresh() { model.refresh() }
    @objc private func quit() { NSApp.terminate(nil) }
}
