import Foundation
import UserNotifications

/// Local notifications for smart notebooks that asked to hear about changes.
/// The last count is kept in defaults so a change is measured across launches,
/// and so turning the alert on doesn't fire on the first count.
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
        let previous = UserDefaults.standard.object(forKey: key) as? Int
        UserDefaults.standard.set(count, forKey: key)
        guard folder.notifyOnChange, let previous, previous != count else { return }
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
        UserDefaults.standard.removeObject(forKey: "smartCount:\(id)")
    }
}
