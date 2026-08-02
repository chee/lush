import SwiftUI
import WebKit
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
    private static var started = false

    static func startIfNeeded() async {
        guard !started else { return }
        started = true
        await controller.start()
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

    static var webRoot: URL? {
        Bundle.main.url(forResource: "PatchworkWeb", withExtension: "bundle")
    }

    static var available: Bool { webRoot != nil }

    static var signerSeedHex: String {
        if let saved = UserDefaults.standard.string(forKey: seedKey) {
            return saved
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(hex, forKey: seedKey)
        return hex
    }

    @MainActor
    static var configScriptTag: String {
        let localPort = LocalSyncServer.wsPort.map { ", \"localWsPort\": \($0)" } ?? ""
        return """
        <script>window.__patchwork_CONFIG = {"publicEndpoint": "\(endpoint)", \
        "signerSeedHex": "\(signerSeedHex)"\(localPort)};</script>
        """
    }

    static let shellHTML = #"""
    <!doctype html>
    <html>
    <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <!-- richweb_CONFIG -->
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
      html, body { margin: 0; height: 100%; }
      body > repo-provider, body > repo-provider > patchwork-view {
        display: block; height: 100%; overflow: auto;
      }
      #status { font: 12px system-ui, sans-serif; color: #888; padding: 12px; }
      .picker { display: flex; flex-direction: column; gap: 6px; padding: 14px;
        font: 13px system-ui, sans-serif; }
      .picker-paste { display: flex; gap: 6px; }
      .picker-paste input { flex: 1; padding: 5px 8px; border-radius: 6px;
        border: 1px solid color-mix(in srgb, currentColor 25%, transparent); }
      .picker-heading { margin-top: 8px; color: #888; font-size: 11px;
        text-transform: uppercase; letter-spacing: 0.04em; }
      .picker button { padding: 6px 10px; border-radius: 6px; cursor: pointer;
        border: 1px solid color-mix(in srgb, currentColor 25%, transparent);
        background: transparent; color: inherit; text-align: left; font: inherit; }
      .picker button:hover { background: color-mix(in srgb, currentColor 8%, transparent); }
    </style>
    </head>
    <body>
    <div id="status">loading patchwork…</div>
    <script type="module" src="/embed.js"></script>
    </body>
    </html>
    """#

    static let shellJS = #"""
    import { initializeWasm, hasHeads } from "@automerge/automerge/slim"
    import {
      initSync as initSubductionSync,
      MemorySigner,
    } from "@automerge/automerge-subduction/slim"
    import {
      Repo,
      isValidAutomergeUrl,
      parseAutomergeUrl,
      stringifyAutomergeUrl,
    } from "@automerge/automerge-repo/slim"
    import { IndexedDBStorageAdapter } from "@automerge/automerge-repo-storage-indexeddb"
    import { registerRepoProviderElement } from "@inkandswitch/patchwork-providers"
    import { registerPatchworkViewElement } from "@inkandswitch/patchwork-elements"
    import { ModuleWatcher, resolvePath } from "@inkandswitch/patchwork-filesystem"
    import {
      registerPlugins,
      unregisterPlugins,
      getSupportedToolsForType,
      getRegistry,
      createDocOfDatatype2,
    } from "@inkandswitch/patchwork-plugins"

    const status = (text) => {
      const el = document.getElementById("status")
      if (el) el.textContent = text
    }

    function hexToBytes(hex) {
      const bytes = new Uint8Array(hex.length / 2)
      for (let i = 0; i < bytes.length; i++) {
        bytes[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16)
      }
      return bytes
    }

    function toBase64(bytes) {
      let binary = ""
      const CHUNK = 0x8000
      for (let i = 0; i < bytes.length; i += CHUNK) {
        binary += String.fromCharCode(...bytes.subarray(i, i + CHUNK))
      }
      return btoa(binary)
    }

    function textResult(statusCode, message) {
      return {
        status: statusCode,
        mimeType: "text/plain",
        base64: toBase64(new TextEncoder().encode(message)),
      }
    }

    function waitForHeads(handle, hexHeads, timeoutMs) {
      if (hasHeads(handle.doc(), hexHeads)) return Promise.resolve(true)
      return new Promise((resolve) => {
        const cleanup = () => {
          handle.off("heads-changed", check)
          clearTimeout(timer)
        }
        const check = () => {
          if (!hasHeads(handle.doc(), hexHeads)) return
          cleanup()
          resolve(true)
        }
        const timer = setTimeout(() => {
          cleanup()
          resolve(false)
        }, timeoutMs)
        handle.on("heads-changed", check)
        check()
      })
    }

    // The JS half of RichWebSchemeHandler: serves file contents out of folder
    // docs for richweb://app/automerge:…/path requests (tool modules, images).
    function installResolver(repo) {
      window.__patchworkResolve = async (raw) => {
        try {
          const [encoded, ...path] = raw.split("/")
          const url = decodeURIComponent(encoded)
          if (!isValidAutomergeUrl(url)) {
            return textResult(400, `invalid automerge url: ${url}`)
          }
          if (path.length && !path[path.length - 1]) path.pop()
          let { heads, hexHeads, documentId } = parseAutomergeUrl(url)
          const baseHandle = await repo.find(stringifyAutomergeUrl({ documentId }))
          if (!heads) {
            heads = baseHandle.heads()
            hexHeads = undefined
          } else if (!(await waitForHeads(baseHandle, hexHeads ?? [], 20000))) {
            return textResult(504, `heads not found for ${url}`)
          }
          const resolved = await resolvePath(
            repo,
            baseHandle.view(heads),
            path.map(decodeURIComponent),
          )
          if (!resolved) {
            return textResult(404, `couldn't resolve ${path.join("/")} in ${url}`)
          }
          const bytes =
            resolved.content instanceof Uint8Array
              ? resolved.content
              : new TextEncoder().encode(String(resolved.content))
          return { status: 200, mimeType: resolved.type, base64: toBase64(bytes) }
        } catch (error) {
          return textResult(500, String(error))
        }
      }
    }

    // Trimmed port of Patchwork's importPackageFromFolderDocUrl: pin the tool
    // doc to its heads, fetch its package.json through the resolver, pick the
    // entry point, and dynamically import it so its plugins can register.
    function resolveEntry(pkg) {
      const conditions = ["patchwork", "browser", "import", "default"]
      const pick = (value) => {
        if (typeof value === "string") return value
        if (value && typeof value === "object") {
          for (const key of conditions) {
            if (key in value) {
              const found = pick(value[key])
              if (found) return found
            }
          }
        }
        return undefined
      }
      if (pkg.exports) {
        const dot =
          typeof pkg.exports === "string" || !("." in pkg.exports)
            ? pkg.exports
            : pkg.exports["."]
        const found = pick(dot)
        if (found) return found
      }
      return pkg.module ?? pkg.main
    }

    async function importToolPackage(repo, toolUrl) {
      let url = toolUrl
      const { heads } = parseAutomergeUrl(url)
      if (!heads) {
        const handle = await repo.find(url)
        url = handle.view(handle.heads()).url
      }
      const base = new URL(`/${encodeURIComponent(url)}/`, location.href)
      const response = await fetch(new URL("package.json", base))
      if (!response.ok) {
        throw new Error(`no package.json in tool doc ${toolUrl}`)
      }
      const entry = resolveEntry(await response.json())
      if (!entry) {
        throw new Error(`no entry point in tool doc ${toolUrl}`)
      }
      const mod = await import(new URL(entry.replace(/^\.\//, ""), base).href)
      if (Array.isArray(mod?.plugins)) {
        registerPlugins(mod.plugins, url)
      }
      return mod
    }

    async function boot() {
      const config = window.__patchwork_CONFIG ?? {}
      status("loading wasm…")
      const [amWasm, subWasm] = await Promise.all([
        fetch("/automerge.wasm").then((r) => r.arrayBuffer()),
        fetch("/subduction.wasm").then((r) => r.arrayBuffer()),
      ])
      initSubductionSync(new Uint8Array(subWasm))
      await initializeWasm(new Uint8Array(amWasm))

      const signer = config.signerSeedHex
        ? MemorySigner.fromBytes(hexToBytes(config.signerSeedHex))
        : new MemorySigner()
      const endpoints = [config.publicEndpoint ?? "wss://subduction.sync.inkandswitch.com"]
      if (config.localWsPort) {
        endpoints.push(`ws://127.0.0.1:${config.localWsPort}`)
      }
      const repo = new Repo({
        storage: new IndexedDBStorageAdapter(),
        signer,
        peerId: `richtext-${Math.random().toString(36).slice(2, 10)}`,
        enableRemoteHeadsGossiping: true,
        subductionWebsocketEndpoints: endpoints,
      })
      window.repo = repo
      installResolver(repo)

      registerRepoProviderElement(repo)
      registerPatchworkViewElement({ repo })

      status("loading tools…")
      const watcher = new ModuleWatcher(
        repo,
        { system: "/modules.json" },
        (name, mod) => {
          if (Array.isArray(mod?.plugins)) registerPlugins(mod.plugins, name)
        },
        unregisterPlugins,
      )
      await watcher.doneLoading

      const params = new URLSearchParams(location.search)
      if (params.get("mode") === "picker") {
        renderPicker(repo)
        return repo
      }
      const docUrl = params.get("doc-url")
      let toolId = params.get("tool-id")
      if (!docUrl) {
        status("no doc-url given")
        return repo
      }
      status("finding document…")
      if (!toolId) {
        let doc
        try {
          const handle = await Promise.race([
            repo.find(docUrl),
            new Promise((_, reject) =>
              setTimeout(() => reject(new Error("timed out")), 15000),
            ),
          ])
          doc = handle.doc()
        } catch (error) {
          console.warn("richtext: could not load embedded doc", error)
        }
        const type = String(doc?.["@patchwork"]?.type ?? "")
        const firstToolFor = (t) =>
          (getSupportedToolsForType(t) ?? []).filter((tool) => !tool.unlisted)[0]?.id
        toolId = firstToolFor(type)
        const suggested = doc?.["@patchwork"]?.suggestedImportUrl
        if (!toolId && suggested && isValidAutomergeUrl(String(suggested))) {
          try {
            status("importing tool…")
            const mod = await importToolPackage(repo, String(suggested))
            toolId =
              firstToolFor(type) ??
              (mod?.plugins ?? []).find(
                (plugin) => plugin?.type === "patchwork:tool",
              )?.id
          } catch (error) {
            console.warn("richtext: suggested tool import failed", error)
          }
        }
      }
      const view = document.createElement("patchwork-view")
      if (toolId) view.setAttribute("tool-id", toolId)
      view.setAttribute("doc-url", docUrl)
      const provider = document.createElement("repo-provider")
      provider.appendChild(view)
      document.body.replaceChildren(provider)
      return repo
    }

    // Create-and-embed picker: list registered datatypes, create a doc of the
    // chosen one (or take a pasted automerge: url), and hand the result to the
    // native side through the "richtext" message handler.
    function renderPicker(repo) {
      const post = (url, tool) => {
        window.webkit?.messageHandlers?.richtext?.postMessage({
          url,
          tool: tool ?? null,
        })
      }
      const datatypes = (getRegistry("patchwork:datatype").all() ?? []).filter(
        (datatype) => !datatype.unlisted,
      )
      const root = document.createElement("div")
      root.className = "picker"

      const pasteRow = document.createElement("div")
      pasteRow.className = "picker-paste"
      const input = document.createElement("input")
      input.placeholder = "paste an automerge: url"
      const embedButton = document.createElement("button")
      embedButton.textContent = "Embed"
      const submitUrl = () => {
        const url = input.value.trim()
        if (url.startsWith("automerge:")) post(url, null)
      }
      embedButton.onclick = submitUrl
      input.onkeydown = (event) => {
        if (event.key === "Enter") submitUrl()
      }
      pasteRow.append(input, embedButton)
      root.append(pasteRow)

      const heading = document.createElement("div")
      heading.className = "picker-heading"
      heading.textContent = "or create a new document"
      root.append(heading)

      for (const datatype of datatypes) {
        const button = document.createElement("button")
        button.className = "picker-type"
        button.textContent = datatype.name ?? datatype.id
        button.onclick = async () => {
          button.disabled = true
          try {
            const loaded = await getRegistry("patchwork:datatype").load(datatype.id)
            const handle = await createDocOfDatatype2(loaded, repo, undefined, undefined)
            const url = handle?.url ?? String(handle)
            const tool = (getSupportedToolsForType(datatype.id) ?? []).filter(
              (tool) => !tool.unlisted,
            )[0]?.id
            post(url, tool)
          } catch (error) {
            status(String(error))
            button.disabled = false
          }
        }
        root.append(button)
      }
      document.body.replaceChildren(root)
    }

    window.patchworkReady = boot().catch((error) => {
      status(String(error))
      throw error
    })
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
        let path = url.path.isEmpty ? "" : String(url.path.dropFirst())
        let firstSegment = path.components(separatedBy: "/").first ?? ""
        if firstSegment.removingPercentEncoding?.hasPrefix("automerge:") == true {
            return try await resolveDocURL(path: path, url: url)
        }
        switch path {
        case "", "embed.html":
            let html = PatchworkWeb.shellHTML.replacingOccurrences(
                of: "<!-- richweb_CONFIG -->",
                with: PatchworkWeb.configScriptTag
            )
            return respond(url: url, data: Data(html.utf8), mime: "text/html; charset=utf-8")
        case "embed.js":
            return respond(url: url, data: Data(PatchworkWeb.shellJS.utf8), mime: "text/javascript")
        case "app.css":
            return try serveBundleCSS(url: url)
        default:
            return try serveBundleFile(path: path, url: url)
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
            "return await window.__patchworkResolve(path)",
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
    /// looked up rather than hardcoded.
    private func serveBundleCSS(url: URL) throws -> (Data, URLResponse) {
        guard let base = PatchworkWeb.webRoot else { throw URLError(.fileDoesNotExist) }
        let assets = base.appendingPathComponent("assets")
        let css = (try? FileManager.default.contentsOfDirectory(
            at: assets,
            includingPropertiesForKeys: nil
        ))?.first { $0.pathExtension == "css" }
        guard let css, let data = try? Data(contentsOf: css) else {
            throw URLError(.fileDoesNotExist)
        }
        return respond(url: url, data: data, mime: "text/css")
    }

    private func serveBundleFile(path: String, url: URL) throws -> (Data, URLResponse) {
        guard let base = PatchworkWeb.webRoot else { throw URLError(.fileDoesNotExist) }
        let fileURL = base.appendingPathComponent(path)
        guard fileURL.standardizedFileURL.path.hasPrefix(base.standardizedFileURL.path),
              FileManager.default.fileExists(atPath: fileURL.path) else {
            throw URLError(.fileDoesNotExist)
        }
        let data = try Data(contentsOf: fileURL)
        return respond(url: url, data: data, mime: Self.mimeType(for: fileURL.pathExtension))
    }

    private static func mimeType(for pathExtension: String) -> String {
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

#if os(macOS)
struct PatchworkWebView: NSViewRepresentable {
    let docUrl: String
    let toolId: String?

    func makeNSView(context: Context) -> WKWebView {
        Self.makeWebView(docUrl: docUrl, toolId: toolId)
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#else
struct PatchworkWebView: UIViewRepresentable {
    let docUrl: String
    let toolId: String?

    func makeUIView(context: Context) -> WKWebView {
        Self.makeWebView(docUrl: docUrl, toolId: toolId)
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#endif

@MainActor
func makePatchworkWebView(
    query: [URLQueryItem],
    messageHandler: (any WKScriptMessageHandler)? = nil
) -> WKWebView {
    let handler = RichWebSchemeHandler()
    let configuration = WKWebViewConfiguration()
    configuration.setURLSchemeHandler(handler, forURLScheme: "richweb")
    if let messageHandler {
        configuration.userContentController.add(messageHandler, name: "richtext")
    }
    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.isInspectable = true
    handler.webView = webView
    #if os(macOS)
    webView.setValue(false, forKey: "drawsBackground")
    #else
    webView.isOpaque = false
    webView.backgroundColor = .clear
    #endif
    var components = URLComponents(string: "richweb://app/embed.html")!
    components.queryItems = query
    webView.load(URLRequest(url: components.url!))
    return webView
}

extension PatchworkWebView {
    @MainActor
    static func makeWebView(docUrl: String, toolId: String?) -> WKWebView {
        var query = [URLQueryItem(name: "doc-url", value: docUrl)]
        if let toolId, !toolId.isEmpty {
            query.append(URLQueryItem(name: "tool-id", value: toolId))
        }
        return makePatchworkWebView(query: query)
    }
}

final class PatchworkPickerBridge: NSObject, WKScriptMessageHandler {
    let onPick: @MainActor (String, String?) -> Void

    init(onPick: @escaping @MainActor (String, String?) -> Void) {
        self.onPick = onPick
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "richtext",
              let body = message.body as? [String: Any],
              let url = body["url"] as? String, url.hasPrefix("automerge:")
        else { return }
        let tool = body["tool"] as? String
        Task { @MainActor in
            self.onPick(url, tool)
        }
    }
}

#if os(macOS)
struct PatchworkPickerView: NSViewRepresentable {
    let onPick: @MainActor (String, String?) -> Void

    func makeCoordinator() -> PatchworkPickerBridge {
        PatchworkPickerBridge(onPick: onPick)
    }

    func makeNSView(context: Context) -> WKWebView {
        makePatchworkWebView(
            query: [URLQueryItem(name: "mode", value: "picker")],
            messageHandler: context.coordinator
        )
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#else
struct PatchworkPickerView: UIViewRepresentable {
    let onPick: @MainActor (String, String?) -> Void

    func makeCoordinator() -> PatchworkPickerBridge {
        PatchworkPickerBridge(onPick: onPick)
    }

    func makeUIView(context: Context) -> WKWebView {
        makePatchworkWebView(
            query: [URLQueryItem(name: "mode", value: "picker")],
            messageHandler: context.coordinator
        )
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#endif

struct PatchworkCreateSheet: View {
    let controller: EditorController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Embed Patchwork Document")
                    .font(.headline)
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
                    .font(.caption)
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

struct PatchworkBoxView: View {
    let docUrl: String
    let toolId: String?

    var body: some View {
        Group {
            if PatchworkWeb.available {
                PatchworkWebView(docUrl: docUrl, toolId: toolId)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "shippingbox")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("Patchwork embed")
                        .font(.caption)
                    Text("Add PatchworkWeb.bundle to the app to render this document.")
                        .font(.caption2)
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
    }
}
