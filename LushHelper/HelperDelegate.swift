import AppKit

/// Lush and the helper never hold the core at the same time. Lush wins: it
/// terminates the helper on launch and starts it again as it quits. Since that
/// launch happens while Lush is still winding down, seeing Lush running at
/// startup means wait, not give up.
@MainActor
final class HelperDelegate: NSObject, NSApplicationDelegate {
    private let sync = HelperSync.shared
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(
            self,
            selector: #selector(lushLaunched(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        workspace.addObserver(
            self,
            selector: #selector(lushTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
        sync.onStateChange = { [weak self] in self?.updateStatusItem() }
        if !lushIsRunning { takeOver() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        sync.stop()
    }

    private var lushIsRunning: Bool {
        !NSRunningApplication
            .runningApplications(withBundleIdentifier: LushShared.mainBundleId)
            .isEmpty
    }

    private func takeOver() {
        if LushShared.helperShowsMenuBar { installStatusItem() }
        Task { await sync.start() }
    }

    private func isLush(_ notification: Notification) -> Bool {
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        return app?.bundleIdentifier == LushShared.mainBundleId
    }

    @objc private func lushLaunched(_ notification: Notification) {
        guard isLush(notification) else { return }
        NSApp.terminate(nil)
    }

    @objc private func lushTerminated(_ notification: Notification) {
        guard isLush(notification), sync.core == nil else { return }
        takeOver()
    }

    // MARK: - Menu bar

    private func installStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "note.text",
            accessibilityDescription: "Lush"
        )
        item.menu = NSMenu()
        statusItem = item
        updateStatusItem()
    }

    private func updateStatusItem() {
        guard let menu = statusItem?.menu else { return }
        menu.removeAllItems()

        let state = NSMenuItem(
            title: sync.connected ? "Syncing" : "Offline",
            action: nil,
            keyEquivalent: ""
        )
        state.isEnabled = false
        menu.addItem(state)

        if !sync.lastEvent.isEmpty {
            let event = NSMenuItem(title: sync.lastEvent, action: nil, keyEquivalent: "")
            event.isEnabled = false
            menu.addItem(event)
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Open Lush", action: #selector(openLush), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Sync Now", action: #selector(syncNow), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Quit Background Sync",
            action: #selector(quit),
            keyEquivalent: "q"
        ))
        for item in menu.items where item.action != nil { item.target = self }
    }

    /// Launching Lush terminates us through the workspace notification, so
    /// there's nothing to tear down here.
    @objc private func openLush() {
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: LushShared.mainBundleId
        ) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func syncNow() {
        sync.syncNow()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
