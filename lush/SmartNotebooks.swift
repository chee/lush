import SwiftUI

enum SmartNotebookAge: Int64, CaseIterable {
    case any = 0
    case day = 1
    case week = 7
    case month = 30
    case year = 365

    var label: String {
        switch self {
        case .any: "Any time"
        case .day: "Last 24 hours"
        case .week: "Last week"
        case .month: "Last month"
        case .year: "Last year"
        }
    }
}

enum SmartNotebookStore {
    private static let key = "smartNotebooks"

    static func load() -> [SmartNotebook] {
        let raw = UserDefaults.standard.array(forKey: key) as? [[String: String]] ?? []
        return raw.compactMap { row in
            guard let id = row["id"] else { return nil }
            return SmartNotebook(
                id: id,
                name: row["name"] ?? "",
                query: row["query"] ?? "",
                kind: row["kind"] ?? "",
                scope: row["scope"] ?? "",
                withinDays: Int64(row["withinDays"] ?? "") ?? 0,
                showCount: row["showCount"] != "0",
                notifyOnChange: row["notifyOnChange"] == "1"
            )
        }
    }

    static func save(_ folders: [SmartNotebook]) {
        let raw = folders.map { folder in
            [
                "id": folder.id,
                "name": folder.name,
                "query": folder.query,
                "kind": folder.kind,
                "scope": folder.scope,
                "withinDays": String(folder.withinDays),
                "showCount": folder.showCount ? "1" : "0",
                "notifyOnChange": folder.notifyOnChange ? "1" : "0",
            ]
        }
        UserDefaults.standard.set(raw, forKey: key)
    }
}

extension NotesModel {
    func smartNotebook(id: String) -> SmartNotebook? {
        smartNotebooks.first { $0.id == id }
    }

    func loadSmartNotebooks() {
        guard let core, let configUrl = accountConfigUrl else { return }
        Task { @MainActor [weak self] in
            let state = await Task.detached { core.configState(configUrl: configUrl) }.value
            guard let self, let state else { return }
            if state.smart.isEmpty, !self.smartNotebooks.isEmpty {
                self.syncConfigSmartNotebooks()
            } else if state.smart != self.smartNotebooks {
                self.smartNotebooks = state.smart
                SmartNotebookStore.save(state.smart)
            }
        }
    }

    func saveSmartNotebook(_ folder: SmartNotebook) {
        if let index = smartNotebooks.firstIndex(where: { $0.id == folder.id }) {
            smartNotebooks[index] = folder
        } else {
            smartNotebooks.append(folder)
        }
        persistSmartNotebooks()
    }

    func reorderSmartNotebook(id: String, adjacentTo targetId: String) {
        guard id != targetId,
              let source = smartNotebooks.firstIndex(where: { $0.id == id }),
              let target = smartNotebooks.firstIndex(where: { $0.id == targetId })
        else { return }
        let folder = smartNotebooks.remove(at: source)
        let adjusted = smartNotebooks.firstIndex { $0.id == targetId } ?? target
        smartNotebooks.insert(
            folder,
            at: source < target ? min(adjusted + 1, smartNotebooks.count) : adjusted
        )
        persistSmartNotebooks()
    }

    func removeSmartNotebook(id: String) {
        smartNotebooks.removeAll { $0.id == id }
        persistSmartNotebooks()
    }

    private func persistSmartNotebooks() {
        SmartNotebookStore.save(smartNotebooks)
        syncConfigSmartNotebooks()
    }

    func syncConfigSmartNotebooks() {
        guard let core, let configUrl = accountConfigUrl else { return }
        let folders = smartNotebooks
        Task.detached {
            try? core.setConfigSmartNotebooks(configUrl: configUrl, folders: folders)
        }
    }

    /// Runs the saved search through the shared runner, so an open Lush and a
    /// background helper always agree about what a notebook holds.
    func smartNotebookHits(_ folder: SmartNotebook) async -> [SearchHit] {
        guard let core else { return [] }
        let tree = notebookTree
        let vector = folder.query.contains("\"")
            ? nil
            : await QueryEmbedding.shared.vector(for: folder.query)
        return await Task.detached {
            SmartNotebookRun.hits(folder, core: core, tree: tree, vector: vector)
        }.value
    }

    var notebookTree: NotebookTree {
        var tree = NotebookTree()
        func walk(_ nodes: [FolderNode]) {
            for node in nodes {
                tree.kinds[node.url] = node.kind
                tree.parents[node.url] = node.parentUrl
                walk(node.children ?? [])
            }
        }
        walk(folderTree)
        return tree
    }

    /// Notes land in bursts while typing, so the count waits for the typing to
    /// stop rather than re-running the search on every change.
    func refreshSmartHits(_ folder: SmartNotebook) {
        smartHitTasks[folder.id]?.cancel()
        smartHitTasks[folder.id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let hits = await self?.smartNotebookHits(folder) else { return }
            self?.smartHits[folder.id] = hits
            await SmartNotebookAlerts.counted(folder, count: hits.count)
        }
    }

    func refreshSmartHits() {
        for folder in smartNotebooks {
            refreshSmartHits(folder)
        }
    }

    /// Counted straight through, no debounce: background time is short and the
    /// caller has to wait for the answer.
    func checkSmartNotebooks() async {
        for folder in smartNotebooks where folder.notifyOnChange {
            let hits = await smartNotebookHits(folder)
            smartHits[folder.id] = hits
            await SmartNotebookAlerts.counted(folder, count: hits.count)
        }
    }
}

struct SmartNotebookEditor: View {
    let existing: SmartNotebook
    var isNew = false
    @Environment(NotesModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var query = ""
    @State private var kind = SmartNotebookKind.any
    @State private var scope = ""
    @State private var age = SmartNotebookAge.any
    @State private var exact = false
    @State private var showCount = true
    @State private var notifyOnChange = false
    @State private var notificationsDenied = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                Section {
                    TextField("Search for", text: $query)
                    Picker("Match", selection: $exact) {
                        Text("Anything like it").tag(false)
                        Text("This exact text").tag(true)
                    }
                } footer: {
                    Text("Quoting part of a search — \"like this\" — makes only that part exact.")
                }
                Picker("Kind", selection: $kind) {
                    ForEach(SmartNotebookKind.allCases, id: \.self) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                Picker("In", selection: $scope) {
                    Text("Everywhere").tag("")
                    ForEach(model.folderChoices(), id: \.url) { choice in
                        Text(choice.path).tag(choice.url)
                    }
                }
                Picker("Modified", selection: $age) {
                    ForEach(SmartNotebookAge.allCases, id: \.self) { age in
                        Text(age.label).tag(age)
                    }
                }
                Section {
                    Toggle("Show how many", isOn: $showCount)
                    Toggle("Notify me when that changes", isOn: $notifyOnChange)
                } footer: {
                    if notificationsDenied {
                        Text("Notifications are turned off for Lush in System Settings.")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isNew ? "New Smart Notebook" : "Smart Notebook")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .onAppear {
            name = existing.name
            exact = isQuotedPhrase(existing.query)
            query = exact ? String(existing.query.dropFirst().dropLast()) : existing.query
            kind = SmartNotebookKind(rawValue: existing.kind) ?? .any
            scope = existing.scope
            age = SmartNotebookAge(rawValue: existing.withinDays) ?? .any
            showCount = existing.showCount
            notifyOnChange = existing.notifyOnChange
        }
        .onChange(of: notifyOnChange) {
            guard notifyOnChange else { return }
            Task { notificationsDenied = await !SmartNotebookAlerts.requestAuthorization() }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 300)
        #endif
    }

    private func save() {
        var text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if exact, !text.isEmpty {
            text = "\"" + text.replacingOccurrences(of: "\"", with: "") + "\""
        }
        model.saveSmartNotebook(
            SmartNotebook(
                id: existing.id,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                query: text,
                kind: kind.rawValue,
                scope: scope,
                withinDays: age.rawValue,
                showCount: showCount,
                notifyOnChange: notifyOnChange
            )
        )
        dismiss()
    }
}

/// The whole query is one quoted phrase, which is how the editor stores
/// "match this exact text".
func isQuotedPhrase(_ query: String) -> Bool {
    query.count > 1 && query.hasPrefix("\"") && query.hasSuffix("\"")
        && !query.dropFirst().dropLast().contains("\"")
}

func newSmartNotebook(query: String = "", scope: String = "") -> SmartNotebook {
    SmartNotebook(
        id: UUID().uuidString,
        name: query.isEmpty ? "" : query,
        query: query,
        kind: "",
        scope: scope,
        withinDays: 0,
        showCount: true,
        notifyOnChange: false
    )
}
