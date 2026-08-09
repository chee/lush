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
        return """
        <script>window.__patchwork_CONFIG = {"publicEndpoint": "\(endpoint)", \
        "signerSeedHex": "\(seed)", "moduleUrls": \(modules), \
        "accountModuleUrl": \(accountModule)\(localPort)};</script>
        """
    }

    static let shellHTML = #"""
    <!doctype html>
    <html>
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
    func mount(toolId: String?, docUrl: String, checkoutUrl: String?) {
        let key = "\(toolId ?? "")|\(docUrl)|\(checkoutUrl ?? "")"
        guard key != applied, let webView else { return }
        applied = key
        Task {
            _ = try? await webView.callAsyncJavaScript(
                """
                await window.patchworkReady
                window.setContextTool(toolId, docUrl, checkoutUrl)
                """,
                arguments: [
                    "toolId": toolId ?? NSNull(),
                    "docUrl": docUrl,
                    "checkoutUrl": checkoutUrl ?? NSNull(),
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
        let webView = makePatchworkWebView(query: query, messageHandler: coordinator)
        coordinator.webView = webView
        coordinator.mount(toolId: toolId, docUrl: docUrl, checkoutUrl: checkoutUrl)
        return webView
    }

    @MainActor
    fileprivate func update(coordinator: PatchworkContextBridge) {
        coordinator.onTools = onTools
        coordinator.mount(toolId: toolId, docUrl: docUrl, checkoutUrl: checkoutUrl)
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

    /// Storage keys come from webview JS, including third-party modules —
    /// dot components must never survive into the path or they escape root.
    private nonisolated func path(for key: [String]) -> URL? {
        var url = root
        for component in key {
            guard !component.isEmpty, component != ".", component != ".." else { return nil }
            let encoded = component.addingPercentEncoding(withAllowedCharacters: Self.safe) ?? component
            guard !encoded.isEmpty, encoded != ".", encoded != ".." else { return nil }
            url.appendPathComponent(encoded)
        }
        let rootPath = root.standardizedFileURL.path
        guard url.standardizedFileURL.path.hasPrefix(rootPath + "/") else { return nil }
        return url
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
        // WebKit delivers script messages on the main thread
        let core = MainActor.assumeIsolated { self.core }
        Task.detached { [self] in
            let (reply, error) = handle(op: op, key: key, body: body, core: core)
            await MainActor.run { replyHandler(reply, error) }
        }
    }

    /// Failed writes must reject the JS promise — acking a save that never
    /// landed silently corrupts the webview repo's storage.
    private nonisolated func handle(
        op: String,
        key: [String],
        body: [String: Any],
        core: Core?
    ) -> ([String: Any]?, String?) {
        let fm = FileManager.default
        switch op {
        case "load":
            guard let url = path(for: key) else { return (nil, "bad storage key") }
            guard let data = try? Data(contentsOf: url) else { return ([:], nil) }
            return (["binary": data.base64EncodedString()], nil)
        case "save":
            guard let base64 = body["binary"] as? String,
                  let data = Data(base64Encoded: base64),
                  let url = path(for: key) else { return (nil, "bad save request") }
            do {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url)
                return ([:], nil)
            } catch {
                return (nil, "save failed: \(error.localizedDescription)")
            }
        case "saveBatch":
            for entry in body["entries"] as? [[String: Any]] ?? [] {
                guard let entryKey = entry["key"] as? [String],
                      let base64 = entry["binary"] as? String,
                      let data = Data(base64Encoded: base64),
                      let url = path(for: entryKey) else { return (nil, "bad saveBatch entry") }
                do {
                    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: url)
                } catch {
                    return (nil, "saveBatch failed: \(error.localizedDescription)")
                }
            }
            return ([:], nil)
        case "remove", "removeRange":
            guard let url = path(for: key) else { return (nil, "bad storage key") }
            do {
                try fm.removeItem(at: url)
            } catch let error as NSError
                where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
                // already gone
            } catch {
                return (nil, "remove failed: \(error.localizedDescription)")
            }
            return ([:], nil)
        case "loadRange":
            var chunks = loadRange(prefix: key)
            if chunks.isEmpty, key.count == 1, let core {
                chunks = core.docStorageChunks(url: "automerge:\(key[0])").map { chunk in
                    ["key": [key[0], "incremental", "core-\(chunk.digest)"],
                     "binary": Data(chunk.bytes).base64EncodedString()]
                }
            }
            return (["chunks": chunks], nil)
        default:
            return (nil, "unknown storage op \(op)")
        }
    }

    private nonisolated func loadRange(prefix: [String]) -> [[String: Any]] {
        guard let base = path(for: prefix) else { return [] }
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }
        var chunks: [[String: Any]] = []
        for case let file as URL in enumerator {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let data = try? Data(contentsOf: file) else { continue }
            let relative = file.path.dropFirst(base.path.count).split(separator: "/")
                .map { String($0).removingPercentEncoding ?? String($0) }
            chunks.append(["key": prefix + relative, "binary": data.base64EncodedString()])
        }
        return chunks
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
}

#if os(macOS)
struct PatchworkBoxWebViewWrapper: NSViewRepresentable {
    let docUrl: String
    let toolId: String?
    var draftUrl: String? = nil
    var checkoutUrl: String? = nil
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
        host.setPatchworkDoc(url: docUrl, toolId: toolId, draftUrl: draftUrl, checkoutUrl: checkoutUrl)
        PatchworkScripting.shared.register(host.webView, for: .doc(docUrl))
        configureActivation(host.webView)
        return host.webView
    }

    @MainActor
    func updateNSView(_ nsView: WKWebView, context: Context) {
        let coord = context.coordinator
        coord.bridge.onTools = onTools
        coord.bridge.onTraits = onTraits
        configureActivation(nsView)
        if coord.lastDocUrl != docUrl || coord.lastToolId != toolId
            || coord.lastDraftUrl != draftUrl || coord.lastCheckoutUrl != checkoutUrl {
            coord.host?.setPatchworkDoc(url: docUrl, toolId: toolId, draftUrl: draftUrl, checkoutUrl: checkoutUrl)
            PatchworkScripting.shared.register(nsView, for: .doc(docUrl))
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
        host.setPatchworkDoc(url: docUrl, toolId: toolId, draftUrl: draftUrl, checkoutUrl: checkoutUrl)
        PatchworkScripting.shared.register(host.webView, for: .doc(docUrl))
        configureActivation(host.webView)
        return host.webView
    }

    @MainActor
    func updateUIView(_ uiView: WKWebView, context: Context) {
        let coord = context.coordinator
        coord.bridge.onTools = onTools
        coord.bridge.onTraits = onTraits
        configureActivation(uiView)
        if coord.lastDocUrl != docUrl || coord.lastToolId != toolId
            || coord.lastDraftUrl != draftUrl || coord.lastCheckoutUrl != checkoutUrl {
            coord.host?.setPatchworkDoc(url: docUrl, toolId: toolId, draftUrl: draftUrl, checkoutUrl: checkoutUrl)
            PatchworkScripting.shared.register(uiView, for: .doc(docUrl))
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
    func callSetDoc(url: String?, toolId: String?, draftUrl: String? = nil, checkoutUrl: String? = nil) {
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
            await window.setDoc(docUrl, toolId, draftUrl, checkoutUrl)
            """,
            arguments: [
                "docUrl": url as Any,
                "toolId": toolId as Any,
                "draftUrl": draftUrl as Any,
                "checkoutUrl": checkoutUrl as Any,
            ],
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
    private var loaded = false

    init(query: [URLQueryItem] = [], messageHandler: (any WKScriptMessageHandler)? = nil) {
        webView = makePatchworkWebView(query: query, messageHandler: messageHandler)
        super.init()
        webView.navigationDelegate = self
    }

    func setPatchworkDoc(url: String?, toolId: String?, draftUrl: String? = nil, checkoutUrl: String? = nil) {
        current = (url, toolId, draftUrl, checkoutUrl)
        if loaded {
            webView.callSetDoc(url: url, toolId: toolId, draftUrl: draftUrl, checkoutUrl: checkoutUrl)
        } else {
            pending = (url, toolId, draftUrl, checkoutUrl)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        if let p = pending {
            pending = nil
            webView.callSetDoc(url: p.url, toolId: p.toolId, draftUrl: p.draftUrl, checkoutUrl: p.checkoutUrl)
        }
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
