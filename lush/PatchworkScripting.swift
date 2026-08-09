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

        var errorDescription: String? { "Patchwork is unavailable." }
    }

    private struct Slot {
        weak var webView: WKWebView?
    }

    private var slots: [Target: Slot] = [:]
    private var headless: PatchworkWebViewHost?

    func register(_ webView: WKWebView, for target: Target) {
        slots = slots.filter { $0.value.webView != nil }
        slots[target] = Slot(webView: webView)
    }

    func unregister(_ target: Target) {
        slots[target] = nil
    }

    func hasLiveView(_ target: Target) -> Bool {
        slots[target]?.webView != nil
    }

    /// Evaluates `source` as an async function body with `repo`, `handle`,
    /// `doc`, and `docUrl` in scope. Returns whatever it returns as JSON text;
    /// values JSON can't hold come back stringified.
    @discardableResult
    func evaluate(
        _ source: String,
        docUrl: String? = nil,
        in target: Target? = nil,
        timeout: TimeInterval = 60
    ) async throws -> String {
        let webView = try webView(for: target, docUrl: docUrl)
        let result = try await webView.callAsyncJavaScript(
            """
            const run = (async () => {
              await window.patchworkReady
              const repo = window.repo
              const handle = docUrl ? await repo.find(docUrl) : null
              const doc = handle ? handle.doc() : null
              const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor
              const fn = new AsyncFunction("repo", "handle", "doc", "docUrl", source)
              return await fn(repo, handle, doc, docUrl)
            })()
            const value = await Promise.race([
              run,
              new Promise((_, reject) =>
                setTimeout(() => reject(new Error("script timed out")), timeoutMs),
              ),
            ])
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
                "docUrl": docUrl as Any,
                "timeoutMs": timeout * 1000,
            ],
            in: nil,
            contentWorld: .page
        )
        return result as? String ?? "null"
    }

    /// The document at `url` as JSON, read through the patchwork repo.
    func documentJSON(_ url: String) async throws -> String {
        try await evaluate("return doc", docUrl: url, in: .headless)
    }

    private func webView(for target: Target?, docUrl: String?) throws -> WKWebView {
        guard PatchworkWeb.available else { throw ScriptError.unavailable }
        if let target, let webView = slots[target]?.webView {
            return webView
        }
        if target == nil, let docUrl, let webView = slots[.doc(docUrl)]?.webView {
            return webView
        }
        if let headless {
            return headless.webView
        }
        let host = PatchworkWebViewHost()
        headless = host
        return host.webView
    }
}
