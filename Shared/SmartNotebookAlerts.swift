import Foundation
import UserNotifications

/// Local notifications for smart notebooks that asked to hear about changes.
/// The last count lives in the group container, so Lush and the helper measure
/// the change against the same number whichever of them is running.
enum SmartNotebookAlerts {
    static func authorized() async -> Bool {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .authorized
    }

    @discardableResult
    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    static func counted(_ folder: SmartNotebook, count: Int) async {
        let key = "smartCount:\(folder.id)"
        let previous = LushShared.defaults.object(forKey: key) as? Int
        LushShared.defaults.set(count, forKey: key)
        guard folder.notifyOnChange, let previous, previous != count else { return }
        if await !authorized(), await !requestAuthorization() { return }
        let content = UNMutableNotificationContent()
        content.title = folder.displayName
        content.body = count > previous
            ? "\(count - previous) new — \(count) in total"
            : "\(previous - count) gone — \(count) left"
        content.sound = .default
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "smart:\(folder.id)", content: content, trigger: nil)
        )
    }

    static func forget(id: String) {
        LushShared.defaults.removeObject(forKey: "smartCount:\(id)")
    }
}
