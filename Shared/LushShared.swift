import Foundation
import Security

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

    /// The account url is a capability — anyone holding it can read and write
    /// the account — so it lives in the keychain, in the app group's access
    /// group so the helper can read it too.
    static var accountUrl: String? {
        get {
            if let saved = keychainAccount() { return saved }
            guard let legacy = defaults.string(forKey: accountKey) else { return nil }
            setKeychainAccount(legacy)
            defaults.removeObject(forKey: accountKey)
            return legacy
        }
        set {
            setKeychainAccount(newValue)
            defaults.removeObject(forKey: accountKey)
        }
    }

    static let accountsKey = "patchworkAccountUrls"
    static let accountNamesKey = "patchworkAccountNames"

    /// Every account she has logged into, the active one included — same
    /// capability rules as `accountUrl`, so the list lives in the keychain too.
    /// A device that only ever knew one account starts with that one.
    static var accountUrls: [String] {
        get {
            let saved = (keychainValue(accountsKey) ?? "")
                .split(separator: "\n")
                .map(String.init)
            if saved.isEmpty, let active = accountUrl { return [active] }
            return saved
        }
        set { setKeychainValue(newValue.joined(separator: "\n"), for: accountsKey) }
    }

    /// Contact names for the account switcher, so it reads as names rather than
    /// urls before the docs have synced. Not a capability.
    static var accountNames: [String: String] {
        get { defaults.dictionary(forKey: accountNamesKey) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: accountNamesKey) }
    }

    private static let accountService = "party.chee.patchwork.lush.account"

    /// Without an access group the query covers every group this process can
    /// reach, so a lookup finds the item whether it was written to the shared
    /// group or, if that was refused, to the app's own.
    private static func accountQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: accountService,
            kSecAttrAccount as String: key,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    private static func keychainValue(_ key: String) -> String? {
        var query = accountQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func setKeychainValue(_ value: String?, for key: String) {
        SecItemDelete(accountQuery(key) as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var attributes = accountQuery(key)
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        attributes[kSecAttrAccessGroup as String] = appGroup
        if SecItemAdd(attributes as CFDictionary, nil) != errSecSuccess {
            attributes.removeValue(forKey: kSecAttrAccessGroup as String)
            SecItemAdd(attributes as CFDictionary, nil)
        }
    }

    private static func keychainAccount() -> String? {
        keychainValue(accountKey)
    }

    private static func setKeychainAccount(_ url: String?) {
        setKeychainValue(url, for: accountKey)
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
