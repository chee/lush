#if os(macOS)
import AppKit

@MainActor
func relaunchLush() {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = true
    NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
        Task { @MainActor in NSApp.terminate(nil) }
    }
}
#endif
