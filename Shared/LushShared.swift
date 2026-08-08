import Foundation

/// State the app and the background helper both need to find: the core's
/// storage, the saved root folders, the account. All of it lives in the app
/// group container, since the two processes have separate sandboxes.
enum LushShared {
    static let appGroup = "group.party.chee.patchwork.lush"
    static let mainBundleId = "party.chee.patchwork.lush"
    static let helperBundleId = "party.chee.patchwork.lush.Helper"
    static let helperName = "Lush Helper"

    static let foldersKey = "folderURLs"
    static let legacyFolderKey = "folderURL"
    static let accountKey = "patchworkAccountUrl"
    static let helperEnabledKey = "backgroundSyncEnabled"
    static let helperMenuBarKey = "backgroundSyncShowsMenuBar"
    static let widgetSnapshotFileName = "LushWidgetSnapshot.json"
    static let folderContentWidgetKind = "FolderContentWidget"

    static let defaults = UserDefaults(suiteName: appGroup) ?? .standard

    static var container: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    static var helperEnabled: Bool {
        get { defaults.object(forKey: helperEnabledKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: helperEnabledKey) }
    }

    static var helperShowsMenuBar: Bool {
        get { defaults.object(forKey: helperMenuBarKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: helperMenuBarKey) }
    }

    static var rootFolderUrls: [String] {
        get {
            if let saved = defaults.stringArray(forKey: foldersKey), !saved.isEmpty { return saved }
            if let legacy = defaults.string(forKey: legacyFolderKey) { return [legacy] }
            return []
        }
        set { defaults.set(newValue, forKey: foldersKey) }
    }

    static var accountUrl: String? {
        get { defaults.string(forKey: accountKey) }
        set {
            if let newValue { defaults.set(newValue, forKey: accountKey) }
            else { defaults.removeObject(forKey: accountKey) }
        }
    }

    /// Both processes open the same sedimentree — safe, since automerge storage
    /// is content addressed — but only one of them runs a core at a time, so
    /// they never share a subduction identity on the wire.
    static func coreDataDirectory() -> URL {
        let fm = FileManager.default
        let legacy = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LushCore", isDirectory: true)
        guard let container else { return legacy }
        let shared = container
            .appendingPathComponent("Library/Application Support/LushCore", isDirectory: true)
        if !fm.fileExists(atPath: shared.path), fm.fileExists(atPath: legacy.path) {
            try? fm.createDirectory(
                at: shared.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            guard (try? fm.moveItem(at: legacy, to: shared)) != nil else { return legacy }
        }
        try? fm.createDirectory(at: shared, withIntermediateDirectories: true)
        return shared
    }

    /// Pre-helper builds kept roots and account in the app's own defaults.
    static func migrateDefaults() {
        let standard = UserDefaults.standard
        guard standard !== defaults else { return }
        if defaults.stringArray(forKey: foldersKey) == nil,
           let roots = standard.stringArray(forKey: foldersKey) {
            defaults.set(roots, forKey: foldersKey)
        }
        if defaults.string(forKey: legacyFolderKey) == nil,
           let folder = standard.string(forKey: legacyFolderKey) {
            defaults.set(folder, forKey: legacyFolderKey)
        }
        if defaults.string(forKey: accountKey) == nil,
           let account = standard.string(forKey: accountKey) {
            defaults.set(account, forKey: accountKey)
        }
    }
}
