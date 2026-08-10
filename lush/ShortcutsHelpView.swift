import SwiftUI

struct ShortcutsHelpView: View {
    @State private var documentURL = ""
    @State private var replURL: String?
    @State private var output = ""
    @State private var replError: String?
    @State private var running = false

    private var targetURL: String? {
        let value = documentURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Shortcuts & JavaScript")
                        .font(.largeTitle.bold())
                    Text("Automate Lush with Shortcuts.app or run JavaScript directly in Patchwork.")
                        .foregroundStyle(.secondary)
                    Text("lush://help/shortcuts")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                helpSection("Script scope") {
                    JavaScriptAPIRow("repo", "The Automerge Repo. Find existing documents or create new ones.")
                    JavaScriptAPIRow("handle", "The selected document handle, or null when Document URL is empty.")
                    JavaScriptAPIRow("doc", "The current immutable document value, or null without a document.")
                    JavaScriptAPIRow("url", "The supplied Automerge URL, or null.")
                    JavaScriptAPIRow("Patchwork", "Lush helpers for folders, datatypes, imports, and connection state.")
                    JavaScriptAPIRow("window.patchwork", "The initialized Patchwork runtime used by embedded tools.")
                }

                helpSection("Repo and document handles") {
                    JavaScriptAPIRow("await repo.find(url)", "Find a document and return its handle.")
                    JavaScriptAPIRow("repo.create(value)", "Create a document. The returned handle has a url.")
                    JavaScriptAPIRow("handle.doc()", "Read the current document value.")
                    JavaScriptAPIRow("handle.change(d => { … })", "Change a document in place.")
                    JavaScriptCodeBlock("""
                    handle.change(d => {
                      d.done = true
                    })
                    return handle.doc()
                    """)
                }

                helpSection("Patchwork helpers") {
                    JavaScriptAPIRow("Patchwork.createDict(value)", "Create a dictionary document and return its URL.")
                    JavaScriptAPIRow("await Patchwork.addToFolder(folderUrl, name, value, type?)", "Create and link a dictionary document.")
                    JavaScriptAPIRow("await Patchwork.addFileToFolder(folderUrl, name, base64, mimeType)", "Create and link a file document.")
                    JavaScriptAPIRow("await Patchwork.listFolder(folderUrl?)", "Return the links in a folder.")
                    JavaScriptAPIRow("await Patchwork.listRootFolders()", "Return the account's root folders.")
                    JavaScriptAPIRow("Patchwork.listDatatypes()", "Return registered Patchwork datatypes.")
                    JavaScriptAPIRow("await Patchwork.importPackage(url, subpath?)", "Import a package from an Automerge URL.")
                    JavaScriptAPIRow("await Patchwork.appleConfig()", "Read the Apple integration configuration.")
                    JavaScriptAPIRow("Patchwork.isConnected()", "Report whether Subduction is connected.")
                    JavaScriptAPIRow("await Patchwork.connectedPeerIds()", "Return connected peer identifiers.")
                }

                helpSection("Results") {
                    Text("Return any JSON-compatible value. Shortcuts receives a JSON file. Undefined returns null. Errors stop the action and show their JavaScript message.")
                        .foregroundStyle(.secondary)
                    JavaScriptCodeBlock("""
                    const notes = await Patchwork.listFolder()
                    return notes.map(({ name, type, url }) => ({ name, type, url }))
                    """)
                }

                GroupBox("Try it") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Shortcuts.repl")
                                .font(.headline)
                            Spacer()
                            if running {
                                ProgressView().controlSize(.small)
                            }
                            Button("Run", action: run)
                                .keyboardShortcut(.return, modifiers: .command)
                                .disabled(running || replURL == nil)
                        }
                        TextField("Document URL (optional)", text: $documentURL)
                            .textFieldStyle(.roundedBorder)
                        if let replURL {
                            PatchworkBoxWebViewWrapper(
                                docUrl: replURL,
                                toolId: "file",
                                onTools: { _, _ in }
                            )
                                .frame(height: 320)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                        } else if let replError {
                            ContentUnavailableView(
                                "REPL Unavailable",
                                systemImage: "exclamationmark.triangle",
                                description: Text(replError)
                            )
                            .frame(height: 180)
                        } else {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .frame(height: 180)
                        }
                        if !output.isEmpty {
                            ScrollView {
                                Text(output)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(replError == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.red))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(8)
                            }
                            .frame(minHeight: 100)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .frame(maxWidth: 820, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Shortcuts & JavaScript")
        .task {
            guard replURL == nil else { return }
            do {
                replURL = try await PatchworkScripting.shared.shortcutsReplURL()
                replError = nil
            } catch {
                replError = error.localizedDescription
            }
        }
        #if os(macOS)
        .frame(minWidth: 700, minHeight: 720)
        #endif
    }

    private func run() {
        guard let replURL else { return }
        running = true
        replError = nil
        Task {
            do {
                output = PatchworkConsole.pretty(
                    try await PatchworkScripting.shared.evaluateRepl(
                        replURL,
                        docUrl: targetURL
                    )
                )
            } catch {
                output = error.localizedDescription
                replError = error.localizedDescription
            }
            running = false
        }
    }

    private func helpSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title2.bold())
            content()
        }
    }
}

private struct JavaScriptAPIRow: View {
    let signature: String
    let detail: String

    init(_ signature: String, _ detail: String) {
        self.signature = signature
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(signature)
                .font(.body.monospaced())
                .textSelection(.enabled)
            Text(detail)
                .foregroundStyle(.secondary)
        }
    }
}

private struct JavaScriptCodeBlock: View {
    let source: String

    init(_ source: String) {
        self.source = source
    }

    var body: some View {
        ScrollView(.horizontal) {
            Text(source)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .padding(12)
        }
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}
