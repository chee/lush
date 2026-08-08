import AppKit

@main
enum LushHelperMain {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = HelperDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}
