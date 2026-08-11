import SwiftUI
import WebKit
import Security
#if canImport(PatchworkServerKit)
import PatchworkServerKit
#endif

/// The in-process subduction server from PatchworkServerKit: relays to the
/// public server and dials iroh friends, giving embeds peer-to-peer reach.
/// Compiles to a no-op until the local package at
/// ~/Desktop/Patchwork/PatchworkServerKit is added to the project.
@MainActor
enum LocalSyncServer {
    #if canImport(PatchworkServerKit)
    static let controller = ServerController()
    private static var startTask: Task<Void, Never>?

    static func startIfNeeded() async {
        if let startTask {
            await startTask.value
        }
        guard controller.port == nil else { return }
        // One sedimentree for the app and the server it hosts: a doc synced
        // through the server is the same copy the core reads.
        ServerController.dataDir = LushShared.coreDataDirectory()
        let task = Task { await controller.start() }
        startTask = task
        await task.value
        // failed starts leave port nil; clear so a later caller can retry
        if controller.port == nil { startTask = nil }
    }

    static var wsPort: UInt16? { controller.port }

    static func addFriend(_ nodeId: String) throws {
        try controller.addFriend(nodeId)
    }

    static var irohNodeId: String? { controller.irohNodeId }
    static var friends: [String] { controller.friends }
    #else
    static func startIfNeeded() async {}
    static var wsPort: UInt16? { nil }
    static func addFriend(_ nodeId: String) throws {}
    static var irohNodeId: String? { nil }
    static var friends: [String] { [] }
    #endif
}

/// Patchwork embeds render in a WKWebView running the patchwork web runtime
/// (custom elements + automerge wasm), reusing the prebuilt artifacts from
/// Patchwork's PatchworkWeb.bundle. The JS repo syncs straight to the public
/// subduction server, the same one the app's Rust core talks to.
enum PatchworkWeb {
    static let endpoint = "wss://subduction.sync.inkandswitch.com"
    private static let seedKey = "patchworkSignerSeedHex"
    private static let seedService = Bundle.main.bundleIdentifier ?? "party.chee.patchwork.lush"
    private static let seedAccount = "patchworkSignerSeed"

    static var webRoot: URL? {
        Bundle.main.url(forResource: "PatchworkWeb", withExtension: "bundle")
    }

    static var available: Bool { webRoot != nil }

    @MainActor
    private static var seedTask: Task<String, Never>?

    @MainActor
    static var signerSeedHex: String {
        get async {
            if let existing = seedTask { return await existing.value }
            let task = Task.detached(priority: .userInitiated) { Self.loadSignerSeedHex() }
            seedTask = task
            return await task.value
        }
    }

    nonisolated private static func loadSignerSeedHex() -> String {
        if let saved = keychainSeed() {
            return saved
        }
        if let legacy = UserDefaults.standard.string(forKey: seedKey) {
            setKeychainSeed(legacy)
            UserDefaults.standard.removeObject(forKey: seedKey)
            return legacy
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max) }
        }
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        setKeychainSeed(hex)
        return hex
    }

    private static func keychainSeed() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: seedService,
            kSecAttrAccount as String: seedAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func setKeychainSeed(_ hex: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: seedService,
            kSecAttrAccount as String: seedAccount,
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = Data(hex.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }

    private static let moduleUrlsKey = "patchworkModuleUrls"
    private static let accountModuleUrlKey = "patchworkAccountModuleUrl"

    static var moduleUrls: [String] {
        UserDefaults.standard.stringArray(forKey: moduleUrlsKey) ?? []
    }

    @MainActor
    static func setModuleUrls(_ urls: [String]) {
        UserDefaults.standard.set(urls, forKey: moduleUrlsKey)
    }

    /// The account's own `.moduleSettingsUrl`, remembered so embeds can load it
    /// before the next login refreshes it.
    static var accountModuleUrl: String? {
        get { UserDefaults.standard.string(forKey: accountModuleUrlKey) }
        set { UserDefaults.standard.set(newValue, forKey: accountModuleUrlKey) }
    }

    @MainActor
    static var coreServerPort: UInt16?

    private static let lastToolsKey = "patchworkLastTools"

    @MainActor
    static func lastTool(for url: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: lastToolsKey) as? [String: String])?[url]
    }

    @MainActor
    static func setLastTool(_ tool: String?, for url: String) {
        var tools = UserDefaults.standard.dictionary(forKey: lastToolsKey) as? [String: String] ?? [:]
        tools[url] = tool
        UserDefaults.standard.set(tools, forKey: lastToolsKey)
    }

    private static let lastContextToolKey = "patchworkLastContextTool"

    @MainActor
    static var lastContextTool: String? {
        get { UserDefaults.standard.string(forKey: lastContextToolKey) }
        set { UserDefaults.standard.set(newValue, forKey: lastContextToolKey) }
    }

    private static let lastToolsByTypeKey = "patchworkLastToolsByType"

    @MainActor
    static func lastTool(forType kind: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: lastToolsByTypeKey) as? [String: String])?[kind]
    }

    @MainActor
    static func setLastTool(_ tool: String?, forType kind: String) {
        var tools = UserDefaults.standard.dictionary(forKey: lastToolsByTypeKey) as? [String: String] ?? [:]
        tools[kind] = tool
        UserDefaults.standard.set(tools, forKey: lastToolsByTypeKey)
    }

    @MainActor
    static func configScriptTag() async -> String {
        let seed = await signerSeedHex
        let ports = [coreServerPort, LocalSyncServer.wsPort].compactMap { $0 }
        let localPort = ports.isEmpty
            ? ""
            : ", \"localWsPorts\": [\(ports.map(String.init).joined(separator: ", "))]"
        // "</script>" inside a module url would break out of the tag and
        // inject script into the privileged page
        let modules = ((try? JSONSerialization.data(withJSONObject: moduleUrls))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]")
            .replacingOccurrences(of: "</", with: "<\\/")
        let accountModule = (accountModuleUrl
            .flatMap { try? JSONSerialization.data(withJSONObject: $0, options: .fragmentsAllowed) }
            .flatMap { String(data: $0, encoding: .utf8) } ?? "null")
            .replacingOccurrences(of: "</", with: "<\\/")
        let account = (LushShared.accountUrl
            .flatMap { try? JSONSerialization.data(withJSONObject: $0, options: .fragmentsAllowed) }
            .flatMap { String(data: $0, encoding: .utf8) } ?? "null")
            .replacingOccurrences(of: "</", with: "<\\/")
        return """
        <script>window.__patchwork_CONFIG = {"publicEndpoint": "\(endpoint)", \
        "signerSeedHex": "\(seed)", "moduleUrls": \(modules), \
        "accountModuleUrl": \(accountModule), "accountUrl": \(account)\(localPort)};</script>
        """
    }

    static let shellHTML = #"""
    <!doctype html>
    <html theme="apple-light" data-theme-light="apple-light" data-theme-dark="apple-dark">
    <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <!-- lushweb_CONFIG -->
    <script type="importmap">{
      "imports": {
        "@automerge/automerge": "/packages/@automerge/automerge.js",
        "@automerge/automerge/slim": "/packages/@automerge/automerge/slim.js",
        "@automerge/automerge-repo": "/packages/@automerge/automerge-repo.js",
        "@automerge/automerge-repo/slim": "/packages/@automerge/automerge-repo/slim.js",
        "@automerge/automerge-repo/worker-port": "/packages/@automerge/automerge-repo/worker-port.js",
        "@automerge/automerge-repo/subduction-websocket-worker-shared": "/packages/@automerge/automerge-repo/subduction-websocket-worker-shared.js",
        "@automerge/automerge-repo-network-messagechannel": "/packages/@automerge/automerge-repo-network-messagechannel.js",
        "@automerge/automerge-repo-network-websocket": "/packages/@automerge/automerge-repo-network-websocket.js",
        "@automerge/automerge-repo-storage-indexeddb": "/packages/@automerge/automerge-repo-storage-indexeddb.js",
        "@automerge/automerge-repo-keyhive": "/packages/@automerge/automerge-repo-keyhive.js",
        "@automerge/automerge-subduction": "/packages/@automerge/automerge-subduction.js",
        "@automerge/automerge-subduction/slim": "/packages/@automerge/automerge-subduction/slim.js",
        "@keyhive/keyhive": "/packages/@keyhive/keyhive.js",
        "@keyhive/keyhive/slim": "/packages/@keyhive/keyhive/slim.js",
        "@inkandswitch/patchwork-bootloader": "/packages/@inkandswitch/patchwork-bootloader.js",
        "@inkandswitch/patchwork-elements": "/packages/@inkandswitch/patchwork-elements.js",
        "@inkandswitch/patchwork-filesystem": "/packages/@inkandswitch/patchwork-filesystem.js",
        "@inkandswitch/patchwork-plugins": "/packages/@inkandswitch/patchwork-plugins.js",
        "@inkandswitch/patchwork-providers": "/packages/@inkandswitch/patchwork-providers.js",
        "@inkandswitch/patchwork": "/packages/@inkandswitch/patchwork.js",
        "@codemirror/state": "/packages/@codemirror/state.js",
        "@codemirror/view": "/packages/@codemirror/view.js",
        "@codemirror/language": "/packages/@codemirror/language.js",
        "@codemirror/commands": "/packages/@codemirror/commands.js",
        "solid-js": "/packages/solid-js.js",
        "solid-js/html": "/packages/solid-js/html.js",
        "solid-js/web": "/packages/solid-js/web.js",
        "solid-js/h": "/packages/solid-js/h.js",
        "solid-js/store": "/packages/solid-js/store.js",
        "solid-js/jsx-runtime": "/packages/solid-js/jsx-runtime.js"
      },
      "scopes": {}
    }</script>
    <link rel="stylesheet" href="/app.css" />
    <style>
      html, body { margin: 0; height: 100%; background: var(--editor-fill); color: var(--editor-line); }
      body > repo-provider, body > repo-provider > patchwork-view {
        display: block; height: 100%; overflow: auto;
        background: var(--editor-fill); color: var(--editor-line);
      }
      body > .context-root {
        display: block; height: 100%; overflow: auto;
        background: var(--editor-fill); color: var(--editor-line);
      }
      .context-root repo-provider, .context-root patchwork-view {
        display: block; height: 100%;
      }
      #status { font: 12px system-ui, sans-serif; color: color-mix(in srgb, var(--editor-line) 55%, transparent); padding: 12px; }
      @keyframes lush-loading-pulse {
        0%, 100% { background-color: color-mix(in srgb, #ffb35c 10%, var(--editor-fill)); }
        50% { background-color: color-mix(in srgb, #ffb35c 26%, var(--editor-fill)); }
      }
      body.loading { animation: lush-loading-pulse 1.8s ease-in-out infinite; }
      .picker { display: flex; flex-direction: column; gap: 6px; padding: 14px;
        font: 13px system-ui, sans-serif; }
      .picker-paste { display: flex; gap: 6px; }
      .picker-paste input { flex: 1; padding: 5px 8px; border-radius: 6px;
        border: 1px solid color-mix(in srgb, currentColor 25%, transparent); }
      .picker-heading { margin-top: 8px; color: color-mix(in srgb, var(--editor-line) 55%, transparent); font-size: 11px;
        text-transform: uppercase; letter-spacing: 0.04em; }
      .picker button { padding: 6px 10px; border-radius: 6px; cursor: pointer;
        border: 1px solid color-mix(in srgb, currentColor 25%, transparent);
        background: transparent; color: inherit; text-align: left; font: inherit; }
      .picker button:hover { background: color-mix(in srgb, currentColor 8%, transparent); }
    </style>
    </head>
    <body class="loading">
    <div id="status"></div>
    <script type="module" src="/embed.js"></script>
    </body>
    </html>
    """#
}

final class RichWebSchemeHandler: NSObject, WKURLSchemeHandler {
    weak var webView: WKWebView?
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask)
        tasks[id] = Task { @MainActor in
            do {
                let (data, response) = try await self.respond(to: urlSchemeTask.request)
                guard self.tasks[id] != nil else { return }
                urlSchemeTask.didReceive(response)
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
            } catch {
                guard self.tasks[id] != nil else { return }
                urlSchemeTask.didFailWithError(error)
            }
            self.tasks[id] = nil
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask)
        tasks[id]?.cancel()
        tasks[id] = nil
    }

    private func respond(to request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url else { throw URLError(.badURL) }
        let encodedPath = String(url.path(percentEncoded: true).dropFirst())
        let path = encodedPath.removingPercentEncoding ?? encodedPath
        let firstSegment = path.components(separatedBy: "/").first ?? ""
        if firstSegment.removingPercentEncoding?.hasPrefix("automerge:") == true {
            return try await resolveDocURL(path: encodedPath, url: url)
        }
        switch path {
        case "", "embed.html":
            let config = await PatchworkWeb.configScriptTag()
            let html = PatchworkWeb.shellHTML.replacingOccurrences(
                of: "<!-- lushweb_CONFIG -->",
                with: config
            )
            return respond(url: url, data: Data(html.utf8), mime: "text/html; charset=utf-8")
        case "app.css":
            return try await serveBundleCSS(url: url)
        case "packages/@inkandswitch/patchwork-plugins.js":
            return try await servePluginsShim(path: path, url: url)
        default:
            return try await serveBundleFile(path: path, url: url)
        }
    }

    private func respond(url: URL, data: Data, mime: String) -> (Data, URLResponse) {
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": mime, "Content-Length": "\(data.count)"]
        )!
        return (data, response)
    }

    private func resolveDocURL(path: String, url: URL) async throws -> (Data, URLResponse) {
        guard let webView else { throw URLError(.cannotConnectToHost) }
        let result = try await webView.callAsyncJavaScript(
            """
            let waited = 0
            while (!window.__patchworkResolve) {
                if (waited >= 15000) throw new Error("resolver never became ready")
                await new Promise(r => setTimeout(r, 50))
                waited += 50
            }
            return await window.__patchworkResolve(path)
            """,
            arguments: ["path": path],
            contentWorld: .page
        ) as? [String: Any]
        guard let result,
              let status = result["status"] as? Int,
              let mimeType = result["mimeType"] as? String,
              let base64 = result["base64"] as? String,
              let data = Data(base64Encoded: base64) else {
            throw URLError(.cannotParseResponse)
        }
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": mimeType, "Content-Length": "\(data.count)"]
        )!
        return (data, response)
    }

    /// The bundle's stylesheet carries a content hash in its name, so it's
    /// looked up rather than hardcoded. The read runs off the main actor —
    /// bundle files reach multiple megabytes (wasm).
    private func serveBundleCSS(url: URL) async throws -> (Data, URLResponse) {
        let data = try await Task.detached(priority: .userInitiated) { () -> Data in
            guard let base = PatchworkWeb.webRoot else { throw URLError(.fileDoesNotExist) }
            let assets = base.appendingPathComponent("assets")
            let css = (try? FileManager.default.contentsOfDirectory(
                at: assets,
                includingPropertiesForKeys: nil
            ))?.first { $0.pathExtension == "css" }
            guard let css, let data = try? Data(contentsOf: css) else {
                throw URLError(.fileDoesNotExist)
            }
            return data
        }.value
        return respond(url: url, data: data, mime: "text/css")
    }

    private func serveBundleFile(path: String, url: URL) async throws -> (Data, URLResponse) {
        let (data, mime) = try await Task.detached(priority: .userInitiated) { () -> (Data, String) in
            guard let base = PatchworkWeb.webRoot else { throw URLError(.fileDoesNotExist) }
            let fileURL = base.appendingPathComponent(path)
            guard fileURL.standardizedFileURL.path.hasPrefix(base.standardizedFileURL.path + "/"),
                  FileManager.default.fileExists(atPath: fileURL.path) else {
                throw URLError(.fileDoesNotExist)
            }
            return (try Data(contentsOf: fileURL), Self.mimeType(for: fileURL.pathExtension))
        }.value
        return respond(url: url, data: data, mime: mime)
    }

    /// patchwork-elements inlines its own copy of patchwork-plugins, so the
    /// bundle ships two plugin registries: the shell and every module register
    /// into the one the bare specifier points at, while <patchwork-view> reads
    /// its own and finds no tool for any id — a full tool menu over a document
    /// that won't open. Serve the specifier from the element's copy instead, so
    /// there is one registry again. Falls back to the bundle's own file when
    /// the chunk isn't shaped as expected or the duplication is gone.
    private func servePluginsShim(path: String, url: URL) async throws -> (Data, URLResponse) {
        let shim = await Task.detached(priority: .userInitiated) { Self.pluginsShim() }.value
        guard let shim else { return try await serveBundleFile(path: path, url: url) }
        return respond(url: url, data: Data(shim.utf8), mime: "text/javascript")
    }

    nonisolated private static func pluginsShim() -> String? {
        guard let base = PatchworkWeb.webRoot else { return nil }
        let packages = base.appendingPathComponent("packages/@inkandswitch")
        guard let elements = try? String(
            contentsOf: packages.appendingPathComponent("patchwork-elements.js"),
            encoding: .utf8
        ),
            let plugins = try? String(
                contentsOf: packages.appendingPathComponent("patchwork-plugins.js"),
                encoding: .utf8
            ),
            let chunk = elements.firstMatch(of: /from "[^"]*\/(assets\/[^"]+)"/)?.1,
            let source = try? String(
                contentsOf: base.appendingPathComponent(String(chunk)),
                encoding: .utf8
            ),
            source.contains("var PluginRegistry"),
            let namespace = source.firstMatch(of: /dist_exports as (\w+)/)?.1,
            let exported = plugins.firstMatch(of: /export \{([^}]*)\}/)?.1
        else { return nil }
        let names = exported
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        return """
        import { \(namespace) as plugins } from "/\(chunk)"
        export const { \(names) } = plugins
        """
    }

    nonisolated private static func mimeType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "html": "text/html; charset=utf-8"
        case "js", "mjs": "text/javascript"
        case "css": "text/css"
        case "json", "map": "application/json"
        case "wasm": "application/wasm"
        case "svg": "image/svg+xml"
        case "png": "image/png"
        case "txt": "text/plain; charset=utf-8"
        default: "application/octet-stream"
        }
    }
}

struct ToolChoice: Identifiable, Equatable {
    let id: String
    let name: String
}

final class PatchworkEmbedBridge: NSObject, WKScriptMessageHandler {
    let onTools: @MainActor @Sendable ([ToolChoice], String?) -> Void

    init(onTools: @escaping @MainActor @Sendable ([ToolChoice], String?) -> Void) {
        self.onTools = onTools
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "lush",
              let body = message.body as? [String: Any],
              body["kind"] as? String == "tools",
              let rawTools = body["tools"] as? [[String: Any]]
        else { return }
        let tools = rawTools.compactMap { raw -> ToolChoice? in
            guard let id = raw["id"] as? String else { return nil }
            return ToolChoice(id: id, name: raw["name"] as? String ?? id)
        }
        let current = body["current"] as? String
        Task { @MainActor in
            self.onTools(tools, current)
        }
    }
}

/// Owns the context-tool webview: it reports the registered context tools to
/// the tab bar and switches the mounted tool without reloading the page.
final class PatchworkContextBridge: NSObject, WKScriptMessageHandler {
    @MainActor var onTools: (@MainActor @Sendable ([ToolChoice]) -> Void)?
    @MainActor weak var webView: WKWebView?
    @MainActor private var applied: String?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "lush",
              let body = message.body as? [String: Any],
              body["kind"] as? String == "context-tools",
              let rawTools = body["tools"] as? [[String: Any]]
        else { return }
        let tools = rawTools.compactMap { raw -> ToolChoice? in
            guard let id = raw["id"] as? String else { return nil }
            return ToolChoice(id: id, name: raw["name"] as? String ?? id)
        }
        Task { @MainActor in
            self.onTools?(tools)
        }
    }

    @MainActor
    func mount(toolId: String?, docUrl: String, checkoutUrl: String?, backingUrl: String?) {
        let key = "\(toolId ?? "")|\(docUrl)|\(checkoutUrl ?? "")|\(backingUrl ?? "")"
        guard key != applied, let webView else { return }
        applied = key
        Task {
            _ = try? await webView.callAsyncJavaScript(
                """
                await window.patchworkReady
                window.setContextTool(toolId, docUrl, checkoutUrl, backingUrl)
                """,
                arguments: [
                    "toolId": toolId ?? NSNull(),
                    "docUrl": docUrl,
                    "checkoutUrl": checkoutUrl ?? NSNull(),
                    "backingUrl": backingUrl ?? NSNull(),
                ],
                in: nil,
                contentWorld: .page
            )
        }
    }
}

struct PatchworkContextToolsView {
    let docUrl: String
    let accountUrl: String?
    let checkoutUrl: String?
    let backingUrl: String?
    let toolId: String?
    let onTools: @MainActor @Sendable ([ToolChoice]) -> Void

    @MainActor
    fileprivate func makeWebView(coordinator: PatchworkContextBridge) -> WKWebView {
        coordinator.onTools = onTools
        var query = [
            URLQueryItem(name: "mode", value: "context"),
            URLQueryItem(name: "doc-url", value: docUrl),
        ]
        if let accountUrl, !accountUrl.isEmpty {
            query.append(URLQueryItem(name: "account-url", value: accountUrl))
        }
        if let checkoutUrl, !checkoutUrl.isEmpty {
            query.append(URLQueryItem(name: "checkout-url", value: checkoutUrl))
        }
        if let backingUrl, !backingUrl.isEmpty {
            query.append(URLQueryItem(name: "backing-url", value: backingUrl))
        }
        let webView = makePatchworkWebView(query: query, messageHandler: coordinator)
        coordinator.webView = webView
        coordinator.mount(toolId: toolId, docUrl: docUrl, checkoutUrl: checkoutUrl, backingUrl: backingUrl)
        return webView
    }

    @MainActor
    fileprivate func update(coordinator: PatchworkContextBridge) {
        coordinator.onTools = onTools
        coordinator.mount(toolId: toolId, docUrl: docUrl, checkoutUrl: checkoutUrl, backingUrl: backingUrl)
    }
}

#if os(macOS)
extension PatchworkContextToolsView: NSViewRepresentable {
    func makeCoordinator() -> PatchworkContextBridge { PatchworkContextBridge() }

    func makeNSView(context: Context) -> WKWebView {
        makeWebView(coordinator: context.coordinator)
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        update(coordinator: context.coordinator)
    }
}
#else
extension PatchworkContextToolsView: UIViewRepresentable {
    func makeCoordinator() -> PatchworkContextBridge { PatchworkContextBridge() }

    func makeUIView(context: Context) -> WKWebView {
        makeWebView(coordinator: context.coordinator)
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        update(coordinator: context.coordinator)
    }
}
#endif

#if os(macOS)
struct PatchworkWebView: NSViewRepresentable {
    let docUrl: String
    let toolId: String?
    var onTools: (@MainActor @Sendable ([ToolChoice], String?) -> Void)?

    func makeCoordinator() -> PatchworkEmbedBridge? {
        onTools.map { PatchworkEmbedBridge(onTools: $0) }
    }

    func makeNSView(context: Context) -> WKWebView {
        Self.makeWebView(docUrl: docUrl, toolId: toolId, bridge: context.coordinator)
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#else
struct PatchworkWebView: UIViewRepresentable {
    let docUrl: String
    let toolId: String?
    var onTools: (@MainActor @Sendable ([ToolChoice], String?) -> Void)?

    func makeCoordinator() -> PatchworkEmbedBridge? {
        onTools.map { PatchworkEmbedBridge(onTools: $0) }
    }

    func makeUIView(context: Context) -> WKWebView {
        Self.makeWebView(docUrl: docUrl, toolId: toolId, bridge: context.coordinator)
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#endif

/// Admission control that queues instead of refusing: a caller over the
/// ceiling waits for a slot, so back-pressure slows the webview down rather
/// than failing its storage. The wait is bounded, so a slot that never comes
/// back fails one op instead of every op after it.
private actor Slots {
    private let limit: Int
    private var used = 0
    private var waiting: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var queue: [UUID] = []

    init(_ limit: Int) { self.limit = limit }

    /// A waiter gives up rather than queueing behind a slot that may never
    /// come back: an unbounded wait turns one leaked transfer into a
    /// permanent stall for every later page.
    func acquire(for timeout: Duration) async -> Bool {
        if used < limit {
            used += 1
            return true
        }
        let id = UUID()
        let expiry = Task { [weak self] in
            try await Task.sleep(for: timeout)
            await self?.expire(id)
        }
        let granted = await withCheckedContinuation { continuation in
            waiting[id] = continuation
            queue.append(id)
        }
        expiry.cancel()
        return granted
    }

    func release() {
        while let id = queue.first {
            queue.removeFirst()
            if let continuation = waiting.removeValue(forKey: id) {
                continuation.resume(returning: true)
                return
            }
        }
        if used > 0 { used -= 1 }
    }

    private func expire(_ id: UUID) {
        guard let continuation = waiting.removeValue(forKey: id) else { return }
        queue.removeAll { $0 == id }
        continuation.resume(returning: false)
    }
}

/// The webviews' automerge-repo storage adapter, backed by app-local files
/// plus a read-through into the Rust core's own storage: the first load of a
/// doc the webview has never stored answers with the core's blobs, so docs
/// the app already holds (module settings, modules, embeds) open instantly
/// with no network sync.
final class NativeWebStorage: NSObject, WKScriptMessageHandlerWithReply {
    static let shared = NativeWebStorage()
    @MainActor var core: Core?

    private let root = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
    )[0].appendingPathComponent("LushWebStorage", isDirectory: true)

    private nonisolated static let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
    private nonisolated static let ipcBytes = 512 * 1024
    private nonisolated static let encodedIPCBytes = ((ipcBytes + 2) / 3) * 4
    private nonisolated static let pageEntries = 32
    private nonisolated static let activeMessages = 64
    private nonisolated static let activeTransfers = 256
    private nonisolated static let activeRanges = 64
    private nonisolated static let transferIdle: TimeInterval = 600
    private nonisolated static let reapInterval: Duration = .seconds(5)
    private nonisolated static let slotWait: Duration = .seconds(60)
    private nonisolated static let maxKeyComponents = 32
    private nonisolated static let maxKeyBytes = 4096
    private nonisolated static let maxComponentBytes = 240
    private nonisolated static let maxSafeInteger: UInt64 = 9_007_199_254_740_991
    private nonisolated static let transfersName = ".lush-transfers"

    private enum Failure: LocalizedError {
        case message(String)

        var errorDescription: String? {
            switch self {
            case let .message(text): text
            }
        }
    }

    /// The page a transfer belongs to, held weakly: a webview torn down
    /// mid-boot never runs the JS that ends its loads and ranges, so the
    /// entries it opened are only recognisable as garbage by their owner
    /// going away.
    private final class PageOwner: @unchecked Sendable {
        private weak var view: AnyObject?
        init(_ view: AnyObject) { self.view = view }
        var gone: Bool { view == nil }
    }

    private struct Victim {
        let file: FileHandle?
        let temporary: URL?

        func discard() {
            if let file { try? file.close() }
            if let temporary { try? FileManager.default.removeItem(at: temporary) }
        }
    }

    private struct SaveTransfer {
        let file: FileHandle
        let temporary: URL
        let destination: URL
        let owner: PageOwner?
        var offset: UInt64
        var touched: Date
        var busy = false
    }

    private enum LoadSource {
        case file(FileHandle)
        case core(url: String, cursor: String)
    }

    private struct LoadTransfer {
        let source: LoadSource
        let size: UInt64
        let owner: PageOwner?
        var offset: UInt64
        var touched: Date
        var busy = false

        func close() {
            if case let .file(file) = source { try? file.close() }
        }
    }

    private struct RangeEntry {
        let cursor: String
        let size: UInt64
        let coreCursor: String?
    }

    private struct RangeTransfer {
        let prefix: [String]
        let entries: [RangeEntry]
        let owner: PageOwner?
        var offset: Int
        var touched: Date
    }

    private let transferLock = NSLock()
    private let storageLock = NSLock()
    private let messageSlots = Slots(NativeWebStorage.activeMessages)
    private let transferSlots = Slots(NativeWebStorage.activeTransfers)
    private let rangeSlots = Slots(NativeWebStorage.activeRanges)
    private var saves: [String: SaveTransfer] = [:]
    private var loads: [String: LoadTransfer] = [:]
    private var ranges: [String: RangeTransfer] = [:]
    private var cleared = false

    override init() {
        super.init()
        try? FileManager.default.removeItem(at: transfersRoot)
        Task.detached { [weak self] in
            guard let container = self?.root.deletingLastPathComponent() else { return }
            let leftovers = (try? FileManager.default.contentsOfDirectory(
                at: container,
                includingPropertiesForKeys: nil
            )) ?? []
            for leftover in leftovers where leftover.pathExtension == "clearing" {
                try? FileManager.default.removeItem(at: leftover)
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.reapInterval)
                guard let self else { return }
                reapTransfers()
            }
        }
    }

    private var transfersRoot: URL {
        root.appendingPathComponent(Self.transfersName, isDirectory: true)
    }

    private var startupResetMarker: URL {
        root.deletingLastPathComponent().appendingPathComponent("LushWebStorage.reset")
    }

    nonisolated var hasPendingStartupReset: Bool {
        FileManager.default.fileExists(atPath: startupResetMarker.path)
    }

    nonisolated func clear() async throws {
        try await Task.detached { [self] in try clear(stopping: true) }.value
    }

    nonisolated func clearForStartupReset() throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: startupResetMarker.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: startupResetMarker, options: .atomic)
        try clear(stopping: false)
        try fm.removeItem(at: startupResetMarker)
    }

    nonisolated func quarantinePendingStartupReset(failure: Error) throws -> URL? {
        storageLock.lock()
        defer { storageLock.unlock() }
        let fm = FileManager.default
        guard fm.fileExists(atPath: startupResetMarker.path) else { return nil }
        for victim in dropAllTransfers() { victim.discard() }
        let error = failure as NSError
        let record = [
            error.domain,
            String(error.code),
            error.localizedDescription,
            String(reflecting: failure),
        ].joined(separator: "\n")
        try Data(record.utf8).write(to: startupResetMarker, options: .atomic)
        var rootQuarantine: URL?
        if fm.fileExists(atPath: root.path) {
            let quarantine = root.deletingLastPathComponent().appendingPathComponent(
                "LushWebStorage-\(UUID().uuidString).quarantine",
                isDirectory: true
            )
            try fm.moveItem(at: root, to: quarantine)
            rootQuarantine = quarantine
        }
        cleared = false
        let markerQuarantine = startupResetMarker.appendingPathExtension("quarantine")
        if fm.fileExists(atPath: markerQuarantine.path) {
            _ = try fm.replaceItemAt(markerQuarantine, withItemAt: startupResetMarker)
        } else {
            try fm.moveItem(at: startupResetMarker, to: markerQuarantine)
        }
        return rootQuarantine ?? markerQuarantine
    }

    /// A transfer that is mid-read owns its handle until it reconciles:
    /// closing it here would pull the file out from under that thread.
    private nonisolated func dropAllTransfers() -> [Victim] {
        transferLock.lock()
        let saveTransfers = saves.values.filter { !$0.busy }
        let loadTransfers = loads.values.filter { !$0.busy }
        freeSlots(transferSlots, count: saves.count + loads.count)
        freeSlots(rangeSlots, count: ranges.count)
        saves.removeAll()
        loads.removeAll()
        ranges.removeAll()
        transferLock.unlock()
        return saveTransfers.map { Victim(file: $0.file, temporary: $0.temporary) }
            + loadTransfers.compactMap { transfer -> Victim? in
                guard case let .file(file) = transfer.source else { return nil }
                return Victim(file: file, temporary: nil)
            }
    }

    /// The tree is renamed out of the way under the lock and deleted after
    /// it: the rename is what makes the storage empty, so nothing waits on a
    /// recursive delete, and no in-flight transfer can land in the tree the
    /// caller was told was cleared.
    private nonisolated func clear(stopping: Bool) throws {
        let discarded = root.deletingLastPathComponent().appendingPathComponent(
            "LushWebStorage-\(UUID().uuidString).clearing",
            isDirectory: true
        )
        var moved = true
        storageLock.lock()
        do {
            try FileManager.default.moveItem(at: root, to: discarded)
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
            moved = false
        } catch {
            storageLock.unlock()
            throw error
        }
        cleared = stopping
        let victims = dropAllTransfers()
        storageLock.unlock()
        for victim in victims { victim.discard() }
        if moved { try FileManager.default.removeItem(at: discarded) }
    }

    /// Storage keys come from webview JS, including third-party modules —
    /// dot components must never survive into the path or they escape root.
    private nonisolated func path(for key: [String]) -> URL? {
        guard !key.isEmpty, key.count <= Self.maxKeyComponents else { return nil }
        var url = root
        var keyBytes = 0
        for component in key {
            guard !component.isEmpty, !component.hasPrefix(".") else { return nil }
            let encoded = component.addingPercentEncoding(withAllowedCharacters: Self.safe) ?? component
            let componentBytes = encoded.utf8.count
            let (nextBytes, overflow) = keyBytes.addingReportingOverflow(componentBytes)
            guard !encoded.isEmpty,
                  !encoded.hasPrefix("."),
                  componentBytes <= Self.maxComponentBytes,
                  !overflow,
                  nextBytes <= Self.maxKeyBytes
            else { return nil }
            keyBytes = nextBytes
            url.appendPathComponent(encoded)
        }
        let rootPath = root.standardizedFileURL.path
        guard url.standardizedFileURL.path.hasPrefix(rootPath + "/") else { return nil }
        return url
    }

    private nonisolated func coreManaged(_ key: [String]) -> Bool {
        key.count >= 3 && key[1] == "incremental" && key[2].hasPrefix("core-")
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard let body = message.body as? [String: Any],
              let op = body["op"] as? String else {
            replyHandler(nil, "bad storage message")
            return
        }
        let key = body["key"] as? [String] ?? []
        // WebKit delivers script messages on the main thread: nothing here
        // may take a lock or touch the disk, admission included.
        let (core, owner) = MainActor.assumeIsolated {
            (self.core, message.webView.map { PageOwner($0) })
        }
        Task.detached { [self] in
            // The slot an opening op needs is taken before the message slot,
            // so a queue of openers can never hold back the ops that free
            // transfers. Ranges have their own pool: a range page nests a
            // load for an oversized entry, and must not be able to starve it.
            let pool: Slots? = switch op {
            case "loadStart", "saveStart": transferSlots
            case "loadRangeStart": rangeSlots
            default: nil
            }
            if let pool, await pool.acquire(for: Self.slotWait) == false {
                await MainActor.run { replyHandler(nil, "\(op) failed: storage is busy") }
                return
            }
            guard await messageSlots.acquire(for: Self.slotWait) else {
                if let pool { freeSlots(pool) }
                await MainActor.run { replyHandler(nil, "\(op) failed: storage is busy") }
                return
            }
            let (reply, error) = handle(op: op, key: key, body: body, core: core, owner: owner)
            await messageSlots.release()
            await MainActor.run { replyHandler(reply, error) }
        }
    }

    /// Failed writes must reject the JS promise — acking a save that never
    /// landed silently corrupts the webview repo's storage.
    private nonisolated func handle(
        op: String,
        key: [String],
        body: [String: Any],
        core: Core?,
        owner: PageOwner?
    ) -> ([String: Any]?, String?) {
        do {
            switch op {
            // The transfer slot the dispatcher took is owned by the entry
            // these make; it goes back the moment no entry exists to own it.
            case "loadStart":
                do {
                    let transfer = try beginLoad(key: key, core: core, owner: owner)
                    if transfer.token.isEmpty { freeSlots(transferSlots) }
                    return (["transfer": transfer.token, "size": NSNumber(value: transfer.size)], nil)
                } catch {
                    freeSlots(transferSlots)
                    throw error
                }
            case "loadChunk":
                guard let token = body["transfer"] as? String,
                      let offset = uint64(body["offset"])
                else { throw Failure.message("bad load chunk") }
                let data = try readLoad(token: token, offset: offset, core: core)
                return (["binary": data.base64EncodedString()], nil)
            case "loadEnd":
                guard let token = body["transfer"] as? String else {
                    throw Failure.message("bad load transfer")
                }
                endLoad(token: token)
                return ([:], nil)
            case "saveBatch":
                guard let entries = body["entries"] as? [[String: Any]],
                      entries.count <= Self.pageEntries
                else { throw Failure.message("bad saveBatch request") }
                var encodedBytes = 0
                for entry in entries {
                    guard let base64 = entry["binary"] as? String else {
                        throw Failure.message("bad saveBatch entry")
                    }
                    let (nextBytes, overflow) = encodedBytes.addingReportingOverflow(base64.utf8.count)
                    guard !overflow, nextBytes <= Self.encodedIPCBytes else {
                        throw Failure.message("saveBatch requires chunking")
                    }
                    encodedBytes = nextBytes
                }
                for entry in entries {
                    guard let entryKey = entry["key"] as? [String],
                          let base64 = entry["binary"] as? String,
                          let url = path(for: entryKey),
                          !coreManaged(entryKey)
                    else { throw Failure.message("bad saveBatch entry") }
                    let data = try decodeChunk(base64)
                    try commit(data: data, to: url)
                }
                return ([:], nil)
            case "saveStart":
                do {
                    return (["transfer": try beginSave(key: key, owner: owner)], nil)
                } catch {
                    freeSlots(transferSlots)
                    throw error
                }
            case "saveChunk":
                guard let token = body["transfer"] as? String,
                      let offset = uint64(body["offset"]),
                      let base64 = body["binary"] as? String,
                      let done = body["done"] as? Bool
                else { throw Failure.message("bad save chunk") }
                try appendSave(
                    token: token,
                    offset: offset,
                    data: decodeChunk(base64),
                    done: done
                )
                return ([:], nil)
            case "saveCancel":
                guard let token = body["transfer"] as? String else {
                    throw Failure.message("bad save transfer")
                }
                cancelSave(token: token)
                return ([:], nil)
            case "remove", "removeRange":
                try removeStorage(key: key)
                return ([:], nil)
            case "loadRangeStart":
                let token: String
                do {
                    token = try beginRange(prefix: key, core: core, owner: owner)
                } catch {
                    freeSlots(rangeSlots)
                    throw error
                }
                // The token only reaches JS with the first page: if that
                // fails nothing will ever end the transfer.
                do {
                    return (try readRange(token: token, core: core), nil)
                } catch {
                    endRange(token: token)
                    throw error
                }
            case "loadRangePage":
                guard let token = body["transfer"] as? String else {
                    throw Failure.message("bad range transfer")
                }
                return (try readRange(token: token, core: core), nil)
            case "loadRangeEnd":
                guard let token = body["transfer"] as? String else {
                    throw Failure.message("bad range transfer")
                }
                endRange(token: token)
                return ([:], nil)
            default:
                return (nil, "unknown storage op \(op)")
            }
        } catch {
            return (nil, "\(op) failed: \(error.localizedDescription)")
        }
    }

    private nonisolated func uint64(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber else { return nil }
        let double = number.doubleValue
        guard double.isFinite,
              double >= 0,
              double <= Double(Self.maxSafeInteger),
              double.rounded(.towardZero) == double
        else { return nil }
        return UInt64(double)
    }

    private nonisolated func freeSlots(_ slots: Slots, count: Int = 1) {
        guard count > 0 else { return }
        Task { for _ in 0..<count { await slots.release() } }
    }

    private nonisolated func decodeChunk(_ base64: String) throws -> Data {
        guard base64.utf8.count <= Self.encodedIPCBytes,
              let data = Data(base64Encoded: base64),
              data.count <= Self.ipcBytes
        else { throw Failure.message("invalid storage chunk") }
        return data
    }

    /// Runs on a schedule, so a slot is never held hostage by a page that
    /// went away without ending its transfers. Only idle or orphaned
    /// transfers are reaped, and never one that is mid-chunk: a client still
    /// making progress must never have the transfer pulled out from under it.
    /// Handles are closed and temporaries unlinked with the lock dropped.
    private nonisolated func reapTransfers() {
        let now = Date()
        let dead = { (touched: Date, owner: PageOwner?, busy: Bool) in
            !busy && (owner?.gone == true || now.timeIntervalSince(touched) > Self.transferIdle)
        }
        var victims: [Victim] = []
        transferLock.lock()
        for (token, transfer) in saves
        where dead(transfer.touched, transfer.owner, transfer.busy) {
            saves.removeValue(forKey: token)
            freeSlots(transferSlots)
            victims.append(Victim(file: transfer.file, temporary: transfer.temporary))
        }
        for (token, transfer) in loads
        where dead(transfer.touched, transfer.owner, transfer.busy) {
            loads.removeValue(forKey: token)
            freeSlots(transferSlots)
            if case let .file(file) = transfer.source {
                victims.append(Victim(file: file, temporary: nil))
            }
        }
        for (token, transfer) in ranges where dead(transfer.touched, transfer.owner, false) {
            dropRangeLocked(token)
        }
        transferLock.unlock()
        for victim in victims { victim.discard() }
    }

    private nonisolated func dropRangeLocked(_ token: String) {
        guard ranges.removeValue(forKey: token) != nil else { return }
        freeSlots(rangeSlots)
    }

    private nonisolated func beginSave(key: [String], owner: PageOwner?) throws -> String {
        guard let destination = path(for: key), !coreManaged(key) else {
            throw Failure.message("bad storage key")
        }
        let fm = FileManager.default
        let token = UUID().uuidString
        let temporary = transfersRoot.appendingPathComponent(token)
        let file: FileHandle
        do {
            storageLock.lock()
            defer { storageLock.unlock() }
            guard !cleared else { throw Failure.message("storage was cleared") }
            try fm.createDirectory(at: transfersRoot, withIntermediateDirectories: true)
            guard fm.createFile(atPath: temporary.path, contents: nil) else {
                throw Failure.message("couldn't create save transfer")
            }
            file = try FileHandle(forWritingTo: temporary)
        } catch {
            try? fm.removeItem(at: temporary)
            throw error
        }
        transferLock.lock()
        saves[token] = SaveTransfer(
            file: file,
            temporary: temporary,
            destination: destination,
            owner: owner,
            offset: 0,
            touched: Date()
        )
        transferLock.unlock()
        return token
    }

    private nonisolated func appendSave(
        token: String,
        offset: UInt64,
        data: Data,
        done: Bool
    ) throws {
        transferLock.lock()
        guard var transfer = saves[token], !transfer.busy else {
            transferLock.unlock()
            throw Failure.message("invalid save transfer")
        }
        let (nextOffset, overflow) = transfer.offset.addingReportingOverflow(UInt64(data.count))
        guard transfer.offset == offset, !overflow else {
            transferLock.unlock()
            cancelSave(token: token)
            throw Failure.message("invalid save offset")
        }
        transfer.busy = true
        transfer.touched = Date()
        saves[token] = transfer
        transferLock.unlock()

        // The write, the fsync and the commit all happen with no lock held;
        // `busy` is what keeps a second chunk out of this transfer.
        do {
            try transfer.file.seek(toOffset: offset)
            try transfer.file.write(contentsOf: data)
            if done {
                try transfer.file.synchronize()
                try transfer.file.close()
            }
        } catch {
            discard(transfer, token: token)
            throw error
        }
        transfer.offset = nextOffset
        transfer.touched = Date()
        transfer.busy = false

        transferLock.lock()
        guard saves[token] != nil else {
            transferLock.unlock()
            discard(transfer, token: token, closing: !done)
            throw Failure.message("save transfer ended")
        }
        if done {
            saves.removeValue(forKey: token)
            freeSlots(transferSlots)
        } else {
            saves[token] = transfer
        }
        transferLock.unlock()
        guard done else { return }
        do {
            try commit(
                temporary: transfer.temporary,
                to: transfer.destination,
                size: transfer.offset
            )
        } catch {
            try? FileManager.default.removeItem(at: transfer.temporary)
            throw error
        }
    }

    private nonisolated func discard(_ transfer: SaveTransfer, token: String, closing: Bool = true) {
        transferLock.lock()
        if saves.removeValue(forKey: token) != nil { freeSlots(transferSlots) }
        transferLock.unlock()
        if closing { try? transfer.file.close() }
        try? FileManager.default.removeItem(at: transfer.temporary)
    }

    /// A chunk in flight owns the handle; cancelling only unhooks the
    /// transfer and leaves the closing to that thread.
    private nonisolated func cancelSave(token: String) {
        transferLock.lock()
        let transfer = saves[token]?.busy == true ? nil : saves[token]
        if saves.removeValue(forKey: token) != nil { freeSlots(transferSlots) }
        transferLock.unlock()
        guard let transfer else { return }
        try? transfer.file.close()
        try? FileManager.default.removeItem(at: transfer.temporary)
    }

    private nonisolated func beginLoad(
        key: [String],
        core: Core?,
        owner: PageOwner?
    ) throws -> (token: String, size: UInt64) {
        let source: LoadSource
        let size: UInt64
        if coreManaged(key), let core, let chunk = try coreChunk(for: key, core: core) {
            source = .core(url: coreDocURL(key), cursor: chunk.cursor)
            size = chunk.byteLen
        } else {
            guard let url = path(for: key) else { throw Failure.message("bad storage key") }
            storageLock.lock()
            defer { storageLock.unlock() }
            guard !cleared else { throw Failure.message("storage was cleared") }
            guard FileManager.default.fileExists(atPath: url.path) else { return ("", 0) }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw Failure.message("bad storage file")
            }
            let file = try FileHandle(forReadingFrom: url)
            size = try file.seekToEnd()
            try file.seek(toOffset: 0)
            source = .file(file)
        }
        let token = UUID().uuidString
        transferLock.lock()
        loads[token] = LoadTransfer(
            source: source,
            size: size,
            owner: owner,
            offset: 0,
            touched: Date()
        )
        transferLock.unlock()
        return (token, size)
    }

    private nonisolated func readLoad(token: String, offset: UInt64, core: Core?) throws -> Data {
        transferLock.lock()
        guard var transfer = loads[token], !transfer.busy else {
            transferLock.unlock()
            throw Failure.message("invalid load transfer")
        }
        guard transfer.offset == offset, offset <= transfer.size else {
            transferLock.unlock()
            endLoad(token: token)
            throw Failure.message("invalid load offset")
        }
        transfer.busy = true
        transfer.touched = Date()
        loads[token] = transfer
        transferLock.unlock()

        // The file read and the core slice happen with no lock held; `busy`
        // is what keeps a second chunk out of this transfer.
        let remaining = transfer.size - offset
        let count = Int(min(remaining, UInt64(Self.ipcBytes)))
        let data: Data
        do {
            switch transfer.source {
            case let .file(file):
                try file.seek(toOffset: offset)
                data = try file.read(upToCount: count) ?? Data()
            case let .core(url, cursor):
                guard let core else { throw Failure.message("core storage is unavailable") }
                data = count == 0
                    ? Data()
                    : try core.docStorageChunkSlice(url: url, cursor: cursor, offset: offset)
            }
            guard data.count <= count, count == 0 || !data.isEmpty else {
                throw Failure.message("storage value ended early")
            }
        } catch {
            finishLoad(transfer, token: token)
            throw error
        }
        let (nextOffset, overflow) = offset.addingReportingOverflow(UInt64(data.count))
        guard !overflow, nextOffset <= transfer.size else {
            finishLoad(transfer, token: token)
            throw Failure.message("storage value changed while loading")
        }
        if nextOffset == transfer.size {
            finishLoad(transfer, token: token)
            return data
        }
        transferLock.lock()
        guard loads[token] != nil else {
            transferLock.unlock()
            transfer.close()
            throw Failure.message("load transfer ended")
        }
        transfer.offset = nextOffset
        transfer.touched = Date()
        transfer.busy = false
        loads[token] = transfer
        transferLock.unlock()
        return data
    }

    private nonisolated func finishLoad(_ transfer: LoadTransfer, token: String) {
        transferLock.lock()
        if loads.removeValue(forKey: token) != nil { freeSlots(transferSlots) }
        transferLock.unlock()
        transfer.close()
    }

    /// A chunk in flight owns the handle; ending only unhooks the transfer
    /// and leaves the closing to that thread.
    private nonisolated func endLoad(token: String) {
        transferLock.lock()
        let transfer = loads[token]?.busy == true ? nil : loads[token]
        if loads.removeValue(forKey: token) != nil { freeSlots(transferSlots) }
        transferLock.unlock()
        transfer?.close()
    }

    private nonisolated func loadSmall(
        key: [String],
        expectedSize: UInt64? = nil
    ) throws -> Data? {
        guard let url = path(for: key) else { throw Failure.message("bad storage key") }
        storageLock.lock()
        defer { storageLock.unlock() }
        guard !cleared else { throw Failure.message("storage was cleared") }
        guard let size = try storedFileSize(url) else { return nil }
        guard size <= UInt64(Self.ipcBytes) else {
            throw Failure.message("load requires chunking")
        }
        if let expectedSize, expectedSize != size {
            throw Failure.message("storage value changed while loading")
        }
        let data = try Data(contentsOf: url)
        guard UInt64(data.count) == size else {
            throw Failure.message("storage value changed while loading")
        }
        return data
    }

    private nonisolated func storedFileSize(_ url: URL) throws -> UInt64? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let values = try url.resourceValues(
            forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              size >= 0
        else { throw Failure.message("bad storage file") }
        return UInt64(size)
    }

    private nonisolated func commit(data: Data, to destination: URL) throws {
        storageLock.lock()
        defer { storageLock.unlock() }
        guard !cleared else { throw Failure.message("storage was cleared") }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: destination, options: .atomic)
    }

    private nonisolated func commit(
        temporary: URL,
        to destination: URL,
        size: UInt64
    ) throws {
        storageLock.lock()
        defer { storageLock.unlock() }
        guard !cleared else { throw Failure.message("storage was cleared") }
        guard try storedFileSize(temporary) == size else {
            throw Failure.message("save transfer changed")
        }
        let fm = FileManager.default
        try fm.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fm.moveItem(at: temporary, to: destination)
        }
    }

    private nonisolated func removeStorage(key: [String]) throws {
        guard let url = path(for: key) else { throw Failure.message("bad storage key") }
        storageLock.lock()
        defer { storageLock.unlock() }
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
        }
    }

    private nonisolated func components(for cursor: String) -> [String] {
        cursor.split(separator: "/").map {
            String($0).removingPercentEncoding ?? String($0)
        }
    }

    private nonisolated func storedRange(prefix: [String]) throws -> [RangeEntry] {
        guard let base = path(for: prefix) else { throw Failure.message("bad storage key") }
        storageLock.lock()
        defer { storageLock.unlock() }
        guard !cleared else { throw Failure.message("storage was cleared") }
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: base,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        ) else { return [] }
        var entries: [RangeEntry] = []
        for case let file as URL in enumerator {
            let relative = file.path.dropFirst(base.path.count).split(separator: "/")
            guard !relative.isEmpty else { continue }
            guard !relative.contains(where: { $0.hasPrefix(".") }) else {
                enumerator.skipDescendants()
                continue
            }
            let values = try file.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let fileSize = values.fileSize,
                  fileSize >= 0
            else { continue }
            let cursor = relative.joined(separator: "/")
            guard cursor.utf8.count <= Self.maxKeyBytes,
                  path(for: prefix + components(for: cursor))?.standardizedFileURL
                    == file.standardizedFileURL
            else {
                NSLog("lush web storage found unreadable key: %@", cursor)
                throw Failure.message("storage range holds an unreadable key")
            }
            entries.append(RangeEntry(cursor: cursor, size: UInt64(fileSize), coreCursor: nil))
        }
        return entries
    }

    private nonisolated func coreDocURL(_ key: [String]) -> String { "automerge:\(key[0])" }

    /// Read-through, not a copy: the core's blobs are listed alongside what
    /// the webview wrote and read straight out of core storage on demand.
    private nonisolated func coreEntries(prefix: [String], core: Core?) throws -> [RangeEntry] {
        guard let core, prefix.count == 2, prefix[1] == "incremental" else { return [] }
        return try core.docStorageChunkList(url: coreDocURL(prefix)).map { chunk in
            guard let encoded = "core-\(chunk.digest)"
                .addingPercentEncoding(withAllowedCharacters: Self.safe),
                  !encoded.isEmpty,
                  encoded.utf8.count <= Self.maxComponentBytes
            else { throw Failure.message("core storage holds an unreadable digest") }
            return RangeEntry(cursor: encoded, size: chunk.byteLen, coreCursor: chunk.cursor)
        }
    }

    /// The listing a range already took stands in for a fresh one: an entry
    /// too big to inline comes back as its own load, and re-listing the doc
    /// once per oversized entry is both slower and a different generation
    /// than the range the page came from.
    private nonisolated func coreChunk(for key: [String], core: Core) throws -> StorageChunk? {
        guard key.count == 3 else { return nil }
        let digest = String(key[2].dropFirst("core-".count))
        if let chunk = rangeCoreChunk(prefix: [key[0], key[1]], digest: digest) { return chunk }
        return try core.docStorageChunkList(url: coreDocURL(key)).first { $0.digest == digest }
    }

    private nonisolated func rangeCoreChunk(prefix: [String], digest: String) -> StorageChunk? {
        transferLock.lock()
        defer { transferLock.unlock() }
        for transfer in ranges.values where transfer.prefix == prefix {
            for entry in transfer.entries {
                guard let cursor = entry.coreCursor,
                      components(for: entry.cursor) == ["core-\(digest)"]
                else { continue }
                return StorageChunk(cursor: cursor, digest: digest, byteLen: entry.size)
            }
        }
        return nil
    }

    private nonisolated func snapshotRange(prefix: [String], core: Core?) throws -> [RangeEntry] {
        var entries = try storedRange(prefix: prefix)
        let stored = Set(entries.map(\.cursor))
        entries += try coreEntries(prefix: prefix, core: core).filter { !stored.contains($0.cursor) }
        entries.sort { $0.cursor < $1.cursor }
        return entries
    }

    private nonisolated func beginRange(
        prefix: [String],
        core: Core?,
        owner: PageOwner?
    ) throws -> String {
        let entries = try snapshotRange(prefix: prefix, core: core)
        let token = UUID().uuidString
        transferLock.lock()
        defer { transferLock.unlock() }
        ranges[token] = RangeTransfer(
            prefix: prefix,
            entries: entries,
            owner: owner,
            offset: 0,
            touched: Date()
        )
        return token
    }

    /// A page carries the bytes of every entry that fits the IPC budget, so
    /// the common case of many small chunks is one message, not one per chunk.
    /// An entry whose bytes won't read fails the whole range: a short page
    /// reads as the document's complete history, and the next compaction
    /// writes a snapshot from it and deletes the chunks it never saw.
    private nonisolated func readRange(token: String, core: Core?) throws -> [String: Any] {
        transferLock.lock()
        guard var transfer = ranges[token] else {
            transferLock.unlock()
            throw Failure.message("invalid range transfer")
        }
        transferLock.unlock()
        var entries: [[String: Any]] = []
        var inlineBytes: UInt64 = 0
        var index = transfer.offset
        while index < transfer.entries.count, entries.count < Self.pageEntries {
            let entry = transfer.entries[index]
            let fits = entry.size <= UInt64(Self.ipcBytes) - inlineBytes
            if !fits, !entries.isEmpty { break }
            index += 1
            var payload: [String: Any] = [
                "key": transfer.prefix + components(for: entry.cursor),
                "size": NSNumber(value: entry.size),
            ]
            if fits {
                let data = try entryData(prefix: transfer.prefix, entry: entry, core: core)
                payload["binary"] = data.base64EncodedString()
                inlineBytes += entry.size
            }
            entries.append(payload)
        }
        let count = index - transfer.offset
        let done = index == transfer.entries.count
        transferLock.lock()
        defer { transferLock.unlock() }
        if done {
            dropRangeLocked(token)
        } else if ranges[token] != nil {
            transfer.offset = index
            transfer.touched = Date()
            ranges[token] = transfer
        }
        return [
            "transfer": token,
            "entries": entries,
            "count": NSNumber(value: count),
            "done": done,
        ]
    }

    private nonisolated func entryData(
        prefix: [String],
        entry: RangeEntry,
        core: Core?
    ) throws -> Data {
        guard let cursor = entry.coreCursor else {
            guard let data = try loadSmall(
                key: prefix + components(for: entry.cursor),
                expectedSize: entry.size
            ) else { throw Failure.message("storage range entry went away") }
            return data
        }
        guard let core else { throw Failure.message("core storage is unavailable") }
        var data = Data()
        while UInt64(data.count) < entry.size {
            let slice = try core.docStorageChunkSlice(
                url: coreDocURL(prefix),
                cursor: cursor,
                offset: UInt64(data.count)
            )
            guard !slice.isEmpty, UInt64(data.count + slice.count) <= entry.size else {
                throw Failure.message("core storage entry changed while loading")
            }
            data.append(slice)
        }
        return data
    }

    private nonisolated func endRange(token: String) {
        transferLock.lock()
        dropRangeLocked(token)
        transferLock.unlock()
    }
}

final class LushErrorBridge: NSObject, WKScriptMessageHandler {
    static let shared = LushErrorBridge()
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        NSLog("lush webview error: %@", message.body as? String ?? "?")
    }
}

extension Notification.Name {
    static let lushDeactivateEmbeds = Notification.Name("io.lush.deactivateEmbeds")
}

/// Embeds are inert until the reader clicks in: wheel and keys pass to the
/// page, so a canvas can't trap scrolling. A click activates (Maps/Figma
/// rule); Escape or focus loss drops back to inert. Full-viewport detail
/// views skip the machine and are always active.
final class EmbedWebView: WKWebView {
    var activatable = false
    var toolCapturesPointer = false
    var onActiveChanged: ((Bool) -> Void)?

    private(set) var isActive = false {
        didSet { if isActive != oldValue { onActiveChanged?(isActive) } }
    }

    func deactivate() {
        isActive = false
    }

    func activate() {
        isActive = true
    }

    #if os(macOS)
    override func mouseDown(with event: NSEvent) {
        if activatable, !isActive {
            isActive = true
            window?.makeFirstResponder(self)
            return
        }
        super.mouseDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        if activatable, !isActive, toolCapturesPointer {
            nextResponder?.scrollWheel(with: event)
            return
        }
        super.scrollWheel(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if activatable, isActive, event.keyCode == 53 {
            isActive = false
            window?.makeFirstResponder(nil)
            return
        }
        if activatable, !isActive {
            nextResponder?.keyDown(with: event)
            return
        }
        super.keyDown(with: event)
    }

    override func resignFirstResponder() -> Bool {
        if activatable { isActive = false }
        return super.resignFirstResponder()
    }
    #endif
}

@MainActor
func makePatchworkWebView(
    query: [URLQueryItem],
    messageHandler: (any WKScriptMessageHandler)? = nil
) -> WKWebView {
    let handler = RichWebSchemeHandler()
    let configuration = WKWebViewConfiguration()
    configuration.setURLSchemeHandler(handler, forURLScheme: "lushweb")
    configuration.userContentController.addScriptMessageHandler(
        NativeWebStorage.shared,
        contentWorld: .page,
        name: "lushstorage"
    )
    configuration.userContentController.add(LushErrorBridge.shared, name: "lusherror")
    if let messageHandler {
        configuration.userContentController.add(messageHandler, name: "lush")
    }
    configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
    let webView = EmbedWebView(frame: .zero, configuration: configuration)
    webView.isInspectable = true
    handler.webView = webView
    #if os(macOS)
    webView.setValue(false, forKey: "drawsBackground")
    #else
    webView.isOpaque = false
    webView.backgroundColor = .clear
    #endif
    var components = URLComponents(string: "lushweb://app/embed.html")!
    components.queryItems = query
    webView.load(URLRequest(url: components.url!))
    return webView
}

extension PatchworkWebView {
    @MainActor
    static func makeWebView(
        docUrl: String,
        toolId: String?,
        bridge: PatchworkEmbedBridge? = nil
    ) -> WKWebView {
        var query = [URLQueryItem(name: "doc-url", value: docUrl)]
        if let toolId, !toolId.isEmpty {
            query.append(URLQueryItem(name: "tool-id", value: toolId))
        }
        return makePatchworkWebView(query: query, messageHandler: bridge)
    }
}

final class MutablePickerBridge: NSObject, WKScriptMessageHandler {
    @MainActor var onPick: (@MainActor @Sendable (String, String?) -> Void)?

    init(onPick: (@MainActor @Sendable (String, String?) -> Void)? = nil) {
        self.onPick = onPick
        super.init()
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "lush",
              let body = message.body as? [String: Any],
              let url = body["url"] as? String, url.hasPrefix("automerge:")
        else { return }
        let tool = body["tool"] as? String
        Task { @MainActor in
            self.onPick?(url, tool)
        }
    }
}

@MainActor
private func makePickerWebView(
    preferredType: String?,
    preferredToolId: String?,
    coordinator: MutablePickerBridge
) -> WKWebView {
    var query = [URLQueryItem(name: "mode", value: "picker")]
    if let preferredType {
        query.append(URLQueryItem(name: "type", value: preferredType))
        query.append(URLQueryItem(name: "tool-id", value: preferredToolId))
    }
    let webView = makePatchworkWebView(query: query, messageHandler: coordinator)
    PatchworkScripting.shared.register(webView, for: .picker)
    return webView
}

#if os(macOS)
struct PatchworkPickerView: NSViewRepresentable {
    let onPick: @MainActor @Sendable (String, String?) -> Void
    var preferredType: String?
    var preferredToolId: String?

    @MainActor
    func makeCoordinator() -> MutablePickerBridge {
        MutablePickerBridge(onPick: onPick)
    }

    @MainActor
    func makeNSView(context: Context) -> WKWebView {
        makePickerWebView(
            preferredType: preferredType,
            preferredToolId: preferredToolId,
            coordinator: context.coordinator
        )
    }

    @MainActor
    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.onPick = onPick
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: MutablePickerBridge) {
        coordinator.onPick = nil
    }
}
#else
struct PatchworkPickerView: UIViewRepresentable {
    let onPick: @MainActor @Sendable (String, String?) -> Void
    var preferredType: String?
    var preferredToolId: String?

    @MainActor
    func makeCoordinator() -> MutablePickerBridge {
        MutablePickerBridge(onPick: onPick)
    }

    @MainActor
    func makeUIView(context: Context) -> WKWebView {
        makePickerWebView(
            preferredType: preferredType,
            preferredToolId: preferredToolId,
            coordinator: context.coordinator
        )
    }

    @MainActor
    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.onPick = onPick
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: MutablePickerBridge) {
        coordinator.onPick = nil
    }
}
#endif

struct PatchworkCreateSheet: View {
    let controller: EditorController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Embed Patchwork Document")
                    .uiFont(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
            }
            if PatchworkWeb.available {
                PatchworkPickerView { url, tool in
                    controller.insertPatchworkEmbed(url: url, tool: tool)
                    dismiss()
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.separator)
                )
            } else {
                Text("Add PatchworkWeb.bundle to the app to create Patchwork documents.")
                    .uiFont(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(16)
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
    }
}


struct NewPatchworkDocSheet: View {
    var preferredType: String?
    var preferredToolId: String?
    let onPick: @MainActor @Sendable (String, String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showingConsole = false

    init(
        preferredType: String? = nil,
        preferredToolId: String? = nil,
        onPick: @escaping @MainActor @Sendable (String, String?) -> Void
    ) {
        self.preferredType = preferredType
        self.preferredToolId = preferredToolId
        self.onPick = onPick
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("New Patchwork Document")
                    .uiFont(.headline)
                Spacer()
                Button {
                    showingConsole.toggle()
                } label: {
                    Label("JavaScript", systemImage: "curlybraces")
                }
                Button("Cancel") { dismiss() }
            }
            if showingConsole {
                PatchworkConsole(target: .picker)
                    .frame(maxHeight: 320)
            }
            if PatchworkWeb.available {
                PatchworkPickerView(onPick: { url, tool in
                    onPick(url, tool ?? preferredToolId)
                    dismiss()
                }, preferredType: preferredType, preferredToolId: preferredToolId)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.separator)
                )
            } else {
                Text("Add PatchworkWeb.bundle to the app to create Patchwork documents.")
                    .uiFont(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(16)
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
    }
}

/// Each embed and detail view owns its webview: storage reads come from the
/// app over IPC, so boot has no network wait, and nothing shared means no
/// stale-doc races when the selection changes.
@MainActor
final class PatchworkBoxCoordinator {
    let bridge = MutablePatchworkBridge()
    var host: PatchworkWebViewHost?
    var lastDocUrl: String?
    var lastToolId: String? = "__unset__"
    var lastDraftUrl: String?
    var lastCheckoutUrl: String?
    var lastBackingUrl: String? = "__unset__"
}

#if os(macOS)
struct PatchworkBoxWebViewWrapper: NSViewRepresentable {
    let docUrl: String
    let toolId: String?
    var draftUrl: String? = nil
    var checkoutUrl: String? = nil
    var backingUrl: String? = nil
    var activatable = false
    var toolCapturesPointer = false
    var active: Binding<Bool>? = nil
    var onTraits: (@MainActor @Sendable (Bool) -> Void)? = nil
    var onTools: @MainActor @Sendable ([ToolChoice], String?) -> Void

    @MainActor
    func makeCoordinator() -> PatchworkBoxCoordinator { PatchworkBoxCoordinator() }

    @MainActor
    func makeNSView(context: Context) -> WKWebView {
        let coord = context.coordinator
        let host = PatchworkWebViewHost(messageHandler: coord.bridge)
        coord.host = host
        coord.bridge.onTools = onTools
        coord.bridge.onTraits = onTraits
        coord.lastDocUrl = docUrl
        coord.lastToolId = toolId
        coord.lastDraftUrl = draftUrl
        coord.lastCheckoutUrl = checkoutUrl
        coord.lastBackingUrl = backingUrl
        host.setPatchworkBacking(backingUrl)
        host.setPatchworkDoc(url: docUrl, toolId: toolId, draftUrl: draftUrl, checkoutUrl: checkoutUrl)
        PatchworkScripting.shared.register(host, for: .doc(docUrl))
        configureActivation(host.webView)
        return host.webView
    }

    @MainActor
    func updateNSView(_ nsView: WKWebView, context: Context) {
        let coord = context.coordinator
        coord.bridge.onTools = onTools
        coord.bridge.onTraits = onTraits
        configureActivation(nsView)
        if coord.lastBackingUrl != backingUrl {
            coord.lastBackingUrl = backingUrl
            coord.host?.setPatchworkBacking(backingUrl)
        }
        if coord.lastDocUrl != docUrl || coord.lastToolId != toolId
            || coord.lastDraftUrl != draftUrl || coord.lastCheckoutUrl != checkoutUrl {
            coord.host?.setPatchworkDoc(url: docUrl, toolId: toolId, draftUrl: draftUrl, checkoutUrl: checkoutUrl)
            if let host = coord.host {
                PatchworkScripting.shared.register(host, for: .doc(docUrl))
            }
            coord.lastDocUrl = docUrl
            coord.lastToolId = toolId
            coord.lastDraftUrl = draftUrl
            coord.lastCheckoutUrl = checkoutUrl
        }
    }

    @MainActor
    private func configureActivation(_ webView: WKWebView) {
        guard let embed = webView as? EmbedWebView else { return }
        embed.activatable = activatable
        embed.toolCapturesPointer = toolCapturesPointer
        guard let active else { return }
        if active.wrappedValue != embed.isActive {
            active.wrappedValue ? embed.activate() : embed.deactivate()
        }
        embed.onActiveChanged = { value in
            Task { @MainActor in active.wrappedValue = value }
        }
    }
}
#else
struct PatchworkBoxWebViewWrapper: UIViewRepresentable {
    let docUrl: String
    let toolId: String?
    var draftUrl: String? = nil
    var checkoutUrl: String? = nil
    var backingUrl: String? = nil
    var activatable = false
    var toolCapturesPointer = false
    var active: Binding<Bool>? = nil
    var onTraits: (@MainActor @Sendable (Bool) -> Void)? = nil
    var onTools: @MainActor @Sendable ([ToolChoice], String?) -> Void

    @MainActor
    func makeCoordinator() -> PatchworkBoxCoordinator { PatchworkBoxCoordinator() }

    @MainActor
    func makeUIView(context: Context) -> WKWebView {
        let coord = context.coordinator
        let host = PatchworkWebViewHost(messageHandler: coord.bridge)
        coord.host = host
        coord.bridge.onTools = onTools
        coord.bridge.onTraits = onTraits
        coord.lastDocUrl = docUrl
        coord.lastToolId = toolId
        coord.lastDraftUrl = draftUrl
        coord.lastCheckoutUrl = checkoutUrl
        coord.lastBackingUrl = backingUrl
        host.setPatchworkBacking(backingUrl)
        host.setPatchworkDoc(url: docUrl, toolId: toolId, draftUrl: draftUrl, checkoutUrl: checkoutUrl)
        PatchworkScripting.shared.register(host, for: .doc(docUrl))
        configureActivation(host.webView)
        return host.webView
    }

    @MainActor
    func updateUIView(_ uiView: WKWebView, context: Context) {
        let coord = context.coordinator
        coord.bridge.onTools = onTools
        coord.bridge.onTraits = onTraits
        configureActivation(uiView)
        if coord.lastBackingUrl != backingUrl {
            coord.lastBackingUrl = backingUrl
            coord.host?.setPatchworkBacking(backingUrl)
        }
        if coord.lastDocUrl != docUrl || coord.lastToolId != toolId
            || coord.lastDraftUrl != draftUrl || coord.lastCheckoutUrl != checkoutUrl {
            coord.host?.setPatchworkDoc(url: docUrl, toolId: toolId, draftUrl: draftUrl, checkoutUrl: checkoutUrl)
            if let host = coord.host {
                PatchworkScripting.shared.register(host, for: .doc(docUrl))
            }
            coord.lastDocUrl = docUrl
            coord.lastToolId = toolId
            coord.lastDraftUrl = draftUrl
            coord.lastCheckoutUrl = checkoutUrl
        }
    }

    /// Inert on touch means the reader's one-finger pan belongs to the page:
    /// touches skip the webview entirely until a tap activates it.
    private func configureActivation(_ webView: WKWebView) {
        guard let embed = webView as? EmbedWebView else { return }
        embed.activatable = activatable
        embed.toolCapturesPointer = toolCapturesPointer
        if let active {
            if active.wrappedValue != embed.isActive {
                active.wrappedValue ? embed.activate() : embed.deactivate()
            }
            embed.onActiveChanged = { value in
                Task { @MainActor in active.wrappedValue = value }
            }
        }
        embed.isUserInteractionEnabled = !activatable || embed.isActive
    }
}
#endif

struct PatchworkBoxView: View {
    let docUrl: String
    let toolId: String?
    var onSelectTool: ((String?) -> Void)?
    var onRemove: (() -> Void)?
    var onResize: ((Double, Double, Bool) -> Void)?
    @State private var tools: [ToolChoice] = []
    @State private var currentTool: String?
    @State private var boxSize: CGSize = .zero
    @State private var dragBase: CGSize?
    @State private var embedActive = false
    @State private var toolCapturesPointer = false

    var body: some View {
        Group {
            if PatchworkWeb.available {
                PatchworkBoxWebViewWrapper(
                    docUrl: docUrl,
                    toolId: toolId,
                    activatable: true,
                    toolCapturesPointer: toolCapturesPointer,
                    active: $embedActive,
                    onTraits: { self.toolCapturesPointer = $0 }
                ) { tools, current in
                    self.tools = tools
                    self.currentTool = current
                }
                #if os(iOS)
                .overlay {
                    if !embedActive {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { embedActive = true }
                    }
                }
                #endif
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "shippingbox")
                        .uiFont(.title2)
                        .foregroundStyle(.secondary)
                    Text("Patchwork embed")
                        .uiFont(.caption)
                    Text("Add PatchworkWeb.bundle to the app to render this document.")
                        .uiFont(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(12)
            }
        }
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.separator)
        )
        .overlay {
            if embedActive {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .lushDeactivateEmbeds)) { _ in
            embedActive = false
        }
        .overlay(alignment: .topTrailing) {
            if onSelectTool != nil || onRemove != nil {
                Menu {
                    if let onSelectTool, !tools.isEmpty {
                        ForEach(tools) { tool in
                            Button {
                                onSelectTool(tool.id)
                            } label: {
                                if tool.id == currentTool {
                                    Label(tool.name, systemImage: "checkmark")
                                } else {
                                    Text(tool.name)
                                }
                            }
                        }
                        Divider()
                        Button("Default") { onSelectTool(nil) }
                        Divider()
                    }
                    if let onRemove {
                        Button("Remove", role: .destructive) { onRemove() }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle.fill")
                        .foregroundStyle(.secondary)
                        .background(Circle().fill(.background))
                }
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .padding(8)
            }
        }
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { boxSize = proxy.size }
                    .onChange(of: proxy.size) { _, size in boxSize = size }
            }
        )
        .overlay(alignment: .bottomTrailing) {
            if onResize != nil {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(5)
                    .background(Circle().fill(.background))
                    .padding(6)
                    .gesture(resizeGesture)
                    #if os(macOS)
                    .onHover { inside in
                        if inside { NSCursor.crosshair.push() } else { NSCursor.pop() }
                    }
                    #endif
            }
        }
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let base = dragBase ?? boxSize
                dragBase = base
                onResize?(
                    max(120, base.width + value.translation.width),
                    max(80, base.height + value.translation.height),
                    false
                )
            }
            .onEnded { value in
                let base = dragBase ?? boxSize
                dragBase = nil
                onResize?(
                    max(120, base.width + value.translation.width),
                    max(80, base.height + value.translation.height),
                    true
                )
            }
    }
}

private extension WKWebView {
    // Waits for boot to define window.setDoc rather than awaiting
    // patchworkReady, which throws here if boot failed and would silently
    // leave the previous doc on screen. Concurrent calls race on their poll
    // timers, so each takes a generation and only the newest may mount —
    // otherwise a stale call can win and show the previous doc.
    func callSetDoc(
        url: String?,
        toolId: String?,
        draftUrl: String? = nil,
        checkoutUrl: String? = nil,
        backingUrl: String? = nil
    ) {
        callAsyncJavaScript(
            """
            window.__lushSetDocGen = (window.__lushSetDocGen ?? 0) + 1
            const gen = window.__lushSetDocGen
            let waited = 0
            while (!window.setDoc) {
                if (gen !== window.__lushSetDocGen) return
                if (waited >= 30000) {
                    console.warn("lush: setDoc never appeared; boot broken?")
                    return
                }
                await new Promise(r => setTimeout(r, 50))
                waited += 50
            }
            if (gen !== window.__lushSetDocGen) return
            await window.setDoc(docUrl, toolId, draftUrl, checkoutUrl, backingUrl)
            """,
            arguments: [
                "docUrl": url as Any,
                "toolId": toolId as Any,
                "draftUrl": draftUrl as Any,
                "checkoutUrl": checkoutUrl as Any,
                "backingUrl": backingUrl as Any,
            ],
            in: nil,
            in: .page,
            completionHandler: nil
        )
    }

    func callSetOverlay(docUrl: String, backingUrl: String?) {
        callAsyncJavaScript(
            """
            let waited = 0
            while (!window.setOverlay) {
                if (waited >= 5000) return
                await new Promise(r => setTimeout(r, 50))
                waited += 50
            }
            window.setOverlay(docUrl, backingUrl)
            """,
            arguments: ["docUrl": docUrl, "backingUrl": backingUrl as Any],
            in: nil,
            in: .page,
            completionHandler: nil
        )
    }
}

@MainActor
final class PatchworkWebViewHost: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    private var pending: (url: String?, toolId: String?, draftUrl: String?, checkoutUrl: String?)?
    private var current: (url: String?, toolId: String?, draftUrl: String?, checkoutUrl: String?)?
    private var backingUrl: String?
    private var loaded = false
    private var loadWaiters: [UUID: CheckedContinuation<Void, any Error>] = [:]

    init(query: [URLQueryItem] = [], messageHandler: (any WKScriptMessageHandler)? = nil) {
        webView = makePatchworkWebView(query: query, messageHandler: messageHandler)
        super.init()
        webView.navigationDelegate = self
    }

    func setPatchworkDoc(url: String?, toolId: String?, draftUrl: String? = nil, checkoutUrl: String? = nil) {
        current = (url, toolId, draftUrl, checkoutUrl)
        if loaded {
            webView.callSetDoc(
                url: url,
                toolId: toolId,
                draftUrl: draftUrl,
                checkoutUrl: checkoutUrl,
                backingUrl: backingUrl
            )
        } else {
            pending = (url, toolId, draftUrl, checkoutUrl)
        }
    }

    func waitUntilLoaded() async throws {
        if loaded { return }
        let id = UUID()
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            self?.finishLoadWaiter(id, with: .failure(URLError(.timedOut)))
        }
        defer { timeout.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if loaded {
                    continuation.resume()
                } else if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    loadWaiters[id] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishLoadWaiter(id, with: .failure(CancellationError()))
            }
        }
    }

    private func finishLoadWaiter(
        _ id: UUID,
        with result: Result<Void, any Error>
    ) {
        loadWaiters.removeValue(forKey: id)?.resume(with: result)
    }

    /// The document the view should really read: the checked-out draft's
    /// clone, pinned to the scrubbed version. Pushed on its own so history
    /// scrubbing re-points the live handle instead of remounting the tool.
    func setPatchworkBacking(_ url: String?) {
        backingUrl = url
        guard loaded, let docUrl = current?.url else { return }
        webView.callSetOverlay(docUrl: docUrl, backingUrl: url)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        let waiters = loadWaiters
        loadWaiters.removeAll()
        waiters.values.forEach { $0.resume() }
        if let p = pending {
            pending = nil
            webView.callSetDoc(
                url: p.url,
                toolId: p.toolId,
                draftUrl: p.draftUrl,
                checkoutUrl: p.checkoutUrl,
                backingUrl: backingUrl
            )
        }
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: any Error
    ) {
        let waiters = loadWaiters
        loadWaiters.removeAll()
        waiters.values.forEach { $0.resume(throwing: error) }
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        let waiters = loadWaiters
        loadWaiters.removeAll()
        waiters.values.forEach { $0.resume(throwing: error) }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        NSLog("lush patchwork webview process died, reloading")
        loaded = false
        // replay the doc once the reloaded page finishes, or the embed
        // comes back blank
        if let current { pending = current }
        webView.reload()
    }
}

final class MutablePatchworkBridge: NSObject, WKScriptMessageHandler {
    @MainActor var onTools: (@MainActor @Sendable ([ToolChoice], String?) -> Void)?
    @MainActor var onTraits: (@MainActor @Sendable (Bool) -> Void)?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "lush",
              let body = message.body as? [String: Any] else { return }
        if body["kind"] as? String == "traits",
           let capturesPointer = body["capturesPointer"] as? Bool {
            Task { @MainActor in
                self.onTraits?(capturesPointer)
            }
            return
        }
        guard body["kind"] as? String == "tools",
              let rawTools = body["tools"] as? [[String: Any]]
        else { return }
        let tools = rawTools.compactMap { raw -> ToolChoice? in
            guard let id = raw["id"] as? String else { return nil }
            return ToolChoice(id: id, name: raw["name"] as? String ?? id)
        }
        let current = body["current"] as? String
        Task { @MainActor in
            self.onTools?(tools, current)
        }
    }
}
