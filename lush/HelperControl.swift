#if os(macOS)
import AppKit
import ServiceManagement

/// `Lush Helper.app` keeps subduction syncing while Lush itself is closed. Only
/// one process opens the core at a time: the app takes it on launch and hands
/// it back when it quits.
@MainActor
enum HelperControl {
    private static var service: SMAppService {
        SMAppService.loginItem(identifier: LushShared.helperBundleId)
    }

    static var bundleUrl: URL? {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LoginItems/\(LushShared.helperName).app")
    }

    static var isRunning: Bool {
        !NSRunningApplication
            .runningApplications(withBundleIdentifier: LushShared.helperBundleId)
            .isEmpty
    }

    static var isRegistered: Bool {
        service.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        LushShared.helperEnabled = enabled
        do {
            if enabled {
                if service.status != .enabled { try service.register() }
            } else {
                if service.status == .enabled { try service.unregister() }
                stop()
            }
        } catch {
            NSLog("lush: login item \(enabled ? "register" : "unregister") failed: \(error)")
        }
    }

    /// Registering is idempotent; doing it every launch also repairs the
    /// registration after the app moves on disk.
    static func registerIfEnabled() {
        guard LushShared.helperEnabled else { return }
        guard service.status != .enabled else { return }
        try? service.register()
    }

    static func stop() {
        for app in NSRunningApplication
            .runningApplications(withBundleIdentifier: LushShared.helperBundleId) {
            app.terminate()
        }
    }

    /// The helper releases the core as soon as it sees us launch, but it has to
    /// finish flushing first — wait for the process to actually go away before
    /// opening our own.
    static func stopAndWait(timeout: TimeInterval = 5) {
        guard isRunning else { return }
        stop()
        let deadline = Date().addingTimeInterval(timeout)
        while isRunning, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        if isRunning {
            for app in NSRunningApplication
                .runningApplications(withBundleIdentifier: LushShared.helperBundleId) {
                app.forceTerminate()
            }
        }
    }

    /// Called from `applicationShouldTerminate`, which waits for the reply so
    /// the helper is up before we go.
    static func start(completion: @escaping () -> Void) {
        guard LushShared.helperEnabled, !isRunning, let bundleUrl else {
            completion()
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: bundleUrl, configuration: configuration) { _, error in
            if let error { NSLog("lush: helper launch failed: \(error)") }
            DispatchQueue.main.async(execute: completion)
        }
    }
}
#endif
