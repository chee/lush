import Foundation
import WebKit

/// Runs JavaScript inside a patchwork embed's page, where `repo`, the doc
/// handle, and the loaded tool modules already live. Detail views and the
/// create picker register their webviews here; anything without a live view
/// falls back to a headless embed that boots the same runtime.
@MainActor
final class PatchworkScripting {
    static let shared = PatchworkScripting()

    enum Target: Hashable {
        case doc(String)
        case picker
        case headless
    }

    enum ScriptError: LocalizedError {
        case unavailable
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .unavailable: "Patchwork is unavailable."
            case .failed(let message): message
            }
        }
    }

    private struct Slot {
        weak var webView: WKWebView?
        weak var host: PatchworkWebViewHost?
    }

    private var slots: [Target: Slot] = [:]
    private var headless: PatchworkWebViewHost?

    func register(_ webView: WKWebView, for target: Target) {
        slots = slots.filter { $0.value.webView != nil }
        slots[target] = Slot(webView: webView, host: nil)
    }

    func register(_ host: PatchworkWebViewHost, for target: Target) {
        slots = slots.filter { $0.value.webView != nil }
        slots[target] = Slot(webView: host.webView, host: host)
    }

    func unregister(_ target: Target) {
        slots[target] = nil
    }

    func hasLiveView(_ target: Target) -> Bool {
        slots[target]?.webView != nil
    }

    /// Evaluates `source` as an async function body with `repo`, `handle`,
    /// `doc`, and `url` in scope. Returns whatever it returns as JSON text;
    /// values JSON can't hold come back stringified.
    @discardableResult
    func evaluate(
        _ source: String,
        docUrl: String? = nil,
        in target: Target? = nil,
        timeout: TimeInterval = 60
    ) async throws -> String {
        let webView = try await webView(for: target, docUrl: docUrl)
        let scriptURL: Any = docUrl.map { $0 as Any } ?? NSNull()
        let result: Any?
        do {
            result = try await webView.callAsyncJavaScript(
                """
                const run = (async () => {
                  let waited = 0
                  while (!window.patchworkReady) {
                    if (waited >= 10000) throw new Error("Patchwork did not load")
                    await new Promise(resolve => setTimeout(resolve, 50))
                    waited += 50
                  }
                  await window.patchworkReady
                  const repo = window.repo
                  const handle = url ? await repo.find(url) : null
                  const doc = handle ? handle.doc() : null
                  const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor
                  const fn = new AsyncFunction("repo", "handle", "doc", "url", "Patchwork", source)
                  return await fn(repo, handle, doc, url, window.Patchwork)
                })()
                let value
                try {
                  value = await Promise.race([
                    run,
                    new Promise((_, reject) =>
                      setTimeout(() => reject(new Error("script timed out")), timeoutMs),
                    ),
                  ])
                } catch (error) {
                  const message = error instanceof Error
                    ? `${error.name}: ${error.message}`
                    : String(error)
                  return `__lush_script_error__${message}`
                }
                if (value === undefined) return "null"
                try {
                  const json = JSON.stringify(value)
                  return json === undefined ? String(value) : json
                } catch (error) {
                  return String(value)
                }
                """,
                arguments: [
                    "source": source,
                    "url": scriptURL,
                    "timeoutMs": timeout * 1000,
                ],
                in: nil,
                contentWorld: .page
            )
        } catch {
            let failure = error as NSError
            let message = failure.userInfo["WKJavaScriptExceptionMessage"] as? String
                ?? failure.localizedDescription
            throw ScriptError.failed(message)
        }
        let output = result as? String ?? "null"
        let errorPrefix = "__lush_script_error__"
        if output.hasPrefix(errorPrefix) {
            throw ScriptError.failed(String(output.dropFirst(errorPrefix.count)))
        }
        return output
    }

    /// The document at `url` as JSON, read through the patchwork repo.
    func documentJSON(_ url: String) async throws -> String {
        try await evaluate("return doc", docUrl: url, in: .headless)
    }

    func shortcutsReplURL() async throws -> String {
        let result = try await evaluate(
            "return await Patchwork.shortcutsReplUrl()",
            in: .headless
        )
        guard let data = result.data(using: .utf8),
              let url = try JSONSerialization.jsonObject(
                with: data,
                options: [.fragmentsAllowed]
              ) as? String,
              url.hasPrefix("automerge:")
        else { throw ScriptError.unavailable }
        return url
    }

    func evaluateRepl(
        _ replURL: String,
        docUrl: String?
    ) async throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: replURL,
            options: [.fragmentsAllowed]
        )
        let literal = String(decoding: data, as: UTF8.self)
        return try await evaluate(
            """
            document.activeElement?.blur()
            await new Promise(resolve => requestAnimationFrame(() => resolve()))
            const replHandle = await repo.find(\(literal))
            const source = replHandle.doc()?.content
            if (typeof source !== "string") throw new Error("Shortcuts.repl is not a text file")
            const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor
            const fn = new AsyncFunction("repo", "handle", "doc", "url", "Patchwork", source)
            return await fn(repo, handle, doc, url, Patchwork)
            """,
            docUrl: docUrl,
            in: .doc(replURL)
        )
    }

    func createDictionary(
        _ dictionary: [String: Any],
        type: String?
    ) async throws -> String {
        var dictionary = dictionary
        if let type {
            var metadata = dictionary["@patchwork"] as? [String: Any] ?? [:]
            metadata["type"] = type
            dictionary["@patchwork"] = metadata
        }
        let data = try JSONSerialization.data(withJSONObject: dictionary)
        let encoded = data.base64EncodedString()
        let result = try await evaluate(
            """
            const bytes = Uint8Array.from(atob("\(encoded)"), c => c.charCodeAt(0))
            const input = JSON.parse(new TextDecoder().decode(bytes))
            return window.Patchwork.createDict(input)
            """,
            in: .headless
        )
        guard let resultData = result.data(using: .utf8),
              let url = try JSONSerialization.jsonObject(
                with: resultData,
                options: [.fragmentsAllowed]
              ) as? String,
              url.hasPrefix("automerge:")
        else { throw ScriptError.unavailable }
        return url
    }

    private func webView(for target: Target?, docUrl: String?) async throws -> WKWebView {
        guard PatchworkWeb.available else { throw ScriptError.unavailable }
        if let target, let slot = slots[target], let webView = slot.webView {
            try await slot.host?.waitUntilLoaded()
            return webView
        }
        if target == nil, let docUrl, let slot = slots[.doc(docUrl)], let webView = slot.webView {
            try await slot.host?.waitUntilLoaded()
            return webView
        }
        if let headless {
            try await headless.waitUntilLoaded()
            return headless.webView
        }
        let host = PatchworkWebViewHost()
        headless = host
        try await host.waitUntilLoaded()
        return host.webView
    }
}
