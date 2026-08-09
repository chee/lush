import AppKit
import Foundation

final class LushDockTilePlugin: NSObject, NSDockTilePlugIn {
    private var dockTile: NSDockTile?

    func setDockTile(_ dockTile: NSDockTile?) {
        self.dockTile = dockTile
        guard let dockTile else { return }
        applyOverlay(to: dockTile)
    }

    private func applyOverlay(to dockTile: NSDockTile) {
        guard let url = DockMenuSnapshot.tileImageURL,
              let image = NSImage(contentsOf: url) else { return }
        let view = NSImageView(frame: NSRect(origin: .zero, size: dockTile.size))
        view.image = image
        view.imageScaling = .scaleProportionallyUpOrDown
        view.autoresizingMask = [.width, .height]
        dockTile.contentView = view
        dockTile.display()
    }

    func dockMenu() -> NSMenu? {
        let menu = NSMenu()
        addRoute("New Note", url: "lush://new", to: menu)
        addRoute("Open Quick Note", url: "lush://show?doc=quick", to: menu)
        addRoute("Quick Capture", url: "lush://capture", to: menu)

        let recents = DockMenuSnapshot.stored.recents.prefix(8)
        if !recents.isEmpty {
            menu.addItem(.separator())
            for recent in recents {
                addRoute(
                    recent.title.isEmpty ? "Untitled" : recent.title,
                    url: "lush://show?doc=\(recent.url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? recent.url)",
                    to: menu
                )
            }
        }
        return menu
    }

    private func addRoute(_ title: String, url: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: #selector(openRoute(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = url
        menu.addItem(item)
    }

    @objc private func openRoute(_ sender: NSMenuItem) {
        guard let route = sender.representedObject as? String,
              let url = URL(string: route) else { return }
        NSWorkspace.shared.open(url)
    }
}
