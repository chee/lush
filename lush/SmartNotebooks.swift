import SwiftUI

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
                notifyOnChange: row["notifyOnChange"] == "1",
                rules: row["rules"] ?? ""
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
                "rules": folder.rules,
            ]
        }
        UserDefaults.standard.set(raw, forKey: key)
    }
}

enum FolderSettingsStore {
    private static let key = "folderSettings"

    static func load() -> [String: FolderSettings] {
        let raw = UserDefaults.standard.dictionary(forKey: key) as? [String: [String: Bool]] ?? [:]
        return raw.reduce(into: [:]) { result, entry in
            result[entry.key] = FolderSettings(
                url: entry.key,
                showCount: entry.value["showCount"] ?? false,
                notifyOnChange: entry.value["notifyOnChange"] ?? false
            )
        }
    }

    static func save(_ settings: [String: FolderSettings]) {
        let raw = settings.mapValues {
            ["showCount": $0.showCount, "notifyOnChange": $0.notifyOnChange]
        }
        UserDefaults.standard.set(raw, forKey: key)
    }
}

extension NotesModel {
    func folderSettings(for url: String) -> FolderSettings {
        folderSettings[url] ?? FolderSettings(url: url, showCount: false, notifyOnChange: false)
    }

    func setFolderSettings(_ settings: FolderSettings) {
        if settings.showCount || settings.notifyOnChange {
            folderSettings[settings.url] = settings
        } else {
            folderSettings.removeValue(forKey: settings.url)
        }
        if !settings.notifyOnChange {
            SmartNotebookAlerts.forget(id: settings.url)
        }
        FolderSettingsStore.save(folderSettings)
        syncConfigFolderSettings()
    }

    func applyConfigFolderSettings(_ settings: [FolderSettings]) {
        let keyed = Dictionary(settings.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
        guard keyed != folderSettings else { return }
        folderSettings = keyed
        FolderSettingsStore.save(keyed)
    }

    func syncConfigFolderSettings() {
        guard let core, let configUrl = accountConfigUrl else { return }
        let settings = Array(folderSettings.values)
        Task.detached {
            try? core.setConfigFolderSettings(configUrl: configUrl, settings: settings)
        }
    }

    func folderNoteCount(_ node: FolderNode) -> Int {
        (node.children ?? []).filter { $0.kind != "folder" }.count
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
            if state.folderSettings.isEmpty, !self.folderSettings.isEmpty {
                self.syncConfigFolderSettings()
            } else {
                self.applyConfigFolderSettings(state.folderSettings)
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

    func moveSmartNotebooks(from: IndexSet, to: Int) {
        smartNotebooks.move(fromOffsets: from, toOffset: to)
        persistSmartNotebooks()
    }

    func reorderSmartNotebook(id: String, adjacentTo targetId: String, after: Bool) {
        let ids = reordered(smartNotebooks.map(\.id), moving: id, adjacentTo: targetId, after: after)
        let next = ids.compactMap { id in smartNotebooks.first { $0.id == id } }
        guard next.count == smartNotebooks.count, next != smartNotebooks else { return }
        smartNotebooks = next
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

    /// A background launch can reach the check before the docs have loaded.
    /// The core says when they have; this only bounds how long it is worth
    /// holding a background task open waiting to hear it.
    private func waitForStartup(timeout: Duration = .seconds(20)) async -> Bool {
        guard !startupSettled else { return true }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.awaitStartup() }
            group.addTask { try? await Task.sleep(for: timeout) }
            _ = await group.next()
            group.cancelAll()
        }
        return startupSettled
    }

    /// Runs the saved search through the shared runner, so an open Lush and a
    /// background helper always agree about what a notebook holds.
    func smartNotebookHits(_ folder: SmartNotebook, notes: [IndexedNote]? = nil) async -> [SearchHit] {
        guard let core else { return [] }
        let tree = notebookTree
        let vectors = await SmartNotebookRun.vectors(for: folder)
        let corpus = if let notes { notes } else { await indexedCorpus() }
        return await Task.detached {
            SmartNotebookRun.hits(folder, core: core, tree: tree, vectors: vectors, notes: corpus)
        }.value
    }

    func indexedCorpus() async -> [IndexedNote] {
        guard let core else { return [] }
        return await Task.detached { core.indexedNotes(limit: SmartNotebookRun.corpusLimit) }.value
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
    ///
    /// Nothing loaded yet counts the same as nothing found, and recording that
    /// zero is what made a notebook report everything gone and then, once the
    /// docs arrived, report it all back again. A count is only worth believing
    /// once there is something to count.
    func checkSmartNotebooks() async {
        // The tree is what the hit filter reads: a hit not in it is dropped,
        // so an unloaded tree turns a full index into no results at all.
        guard await waitForStartup(), !folderTree.isEmpty else { return }
        let corpus = smartNotebooks.contains(where: \.notifyOnChange) ? await indexedCorpus() : []
        for folder in smartNotebooks where folder.notifyOnChange {
            let hits = await smartNotebookHits(folder, notes: corpus)
            smartHits[folder.id] = hits
            await SmartNotebookAlerts.counted(folder, count: hits.count)
        }
        for settings in folderSettings.values where settings.notifyOnChange {
            guard let node = node(for: settings.url) else { continue }
            await SmartNotebookAlerts.counted(
                id: settings.url,
                name: node.displayName,
                notify: true,
                count: folderNoteCount(node)
            )
        }
    }
}

struct SmartNotebookEditor: View {
    let existing: SmartNotebook
    var isNew = false
    @Environment(NotesModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var root = SmartRule.group(.all, [])
    @State private var showCount = true
    @State private var notifyOnChange = false
    @State private var notificationsDenied = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                Section {
                    SmartRuleGroup(rule: $root, depth: 0)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                } header: {
                    Text("Rules")
                } footer: {
                    Text(
                        "“Contains” is loose: it ignores case and accents, and a Note rule also "
                            + "finds notes that mean the same thing without saying it. "
                            + "“Exactly” matches the characters as typed."
                    )
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
            root = existing.rootRule
            showCount = existing.showCount
            notifyOnChange = existing.notifyOnChange
        }
        .onChange(of: notifyOnChange) {
            guard notifyOnChange else { return }
            Task { notificationsDenied = await !SmartNotebookAlerts.requestAuthorization() }
        }
        #if os(macOS)
        .frame(minWidth: 620, minHeight: 460)
        #endif
    }

    private func save() {
        model.saveSmartNotebook(
            smartNotebook(
                id: existing.id,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                root: root,
                showCount: showCount,
                notifyOnChange: notifyOnChange
            )
        )
        dismiss()
    }
}

/// A block of rules. Nested groups are the same view one level in: a group is
/// a closed box that holds its children on every side, which is what makes the
/// nesting readable without reading the words.
struct SmartRuleGroup: View {
    @Binding var rule: SmartRule
    let depth: Int
    var remove: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Match")
                Picker("", selection: $rule.op) {
                    ForEach(SmartRule.Op.allCases, id: \.self) { op in
                        Text(op.label).tag(op)
                    }
                }
                .labelsHidden()
                .fixedSize()
                Text("of these")
                Spacer(minLength: 4)
                if let remove {
                    RuleDeleteButton(remove: remove)
                }
            }
            .font(.callout.weight(.medium))
            ForEach($rule.children) { $child in
                if child.isGroup {
                    SmartRuleGroup(rule: $child, depth: depth + 1, remove: { drop(child.id) })
                } else {
                    SmartRuleRow(rule: $child, remove: { drop(child.id) })
                }
            }
            SmartRuleAddMenu(add: add)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ruleBox(groupFill, groupStroke, radius: 12))
    }

    private func add(_ body: SmartRule.Body) {
        withAnimation(.snappy) { rule.children.append(SmartRule(body)) }
    }

    private func drop(_ id: UUID) {
        withAnimation(.snappy) { rule.children.removeAll { $0.id == id } }
    }
}

struct SmartRuleRow: View {
    @Binding var rule: SmartRule
    let remove: () -> Void
    @Environment(NotesModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            SmartRuleTypeMenu(rule: $rule)
            comparison
            value
                .layoutPriority(1)
            RuleDeleteButton(remove: remove)
        }
        .font(.callout)
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ruleBox(rowFill, rowStroke, radius: 9))
    }

    @ViewBuilder private var comparison: some View {
        switch rule.body {
        case let .text(field, whole, exact, text):
            Picker("", selection: bind(SmartTextOp(whole: whole, exact: exact)) {
                .text(field, whole: $0.isWhole, exact: $0.isExact, text)
            }) {
                ForEach(SmartTextOp.allCases, id: \.self) { op in
                    if field.canBeWhole || !op.isWhole {
                        Text(op.label).tag(op)
                    }
                }
            }
            .labelsHidden()
            .fixedSize()
        case let .date(on, op, age, day):
            Picker("", selection: bind(op) { .date(on, $0, age: age, day: day) }) {
                ForEach(SmartDateOp.allCases, id: \.self) { op in
                    Text(op.label).tag(op)
                }
            }
            .labelsHidden()
            .fixedSize()
        case .kind:
            Text("is").foregroundStyle(.secondary)
        case .folder:
            EmptyView()
        case .group:
            EmptyView()
        }
    }

    @ViewBuilder private var value: some View {
        switch rule.body {
        case let .text(field, whole, exact, text):
            TextField("text to find", text: bind(text) { .text(field, whole: whole, exact: exact, $0) })
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 120)
        case let .kind(kind):
            Picker("", selection: bind(kind) { .kind($0) }) {
                ForEach(SmartNotebookKind.allCases, id: \.self) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .labelsHidden()
            .fixedSize()
        case let .folder(url):
            Picker("", selection: bind(url) { .folder($0) }) {
                Text("Everywhere").tag("")
                ForEach(model.folderChoices(), id: \.url) { choice in
                    Text(choice.path).tag(choice.url)
                }
            }
            .labelsHidden()
            .frame(minWidth: 120)
        case let .date(on, op, age, day):
            if op.wantsDay {
                DatePicker(
                    "",
                    selection: bind(smartRuleDayStart(day) ?? Date()) {
                        .date(on, op, age: age, day: smartRuleDay($0))
                    },
                    displayedComponents: .date
                )
                .labelsHidden()
                .fixedSize()
            } else {
                Picker("", selection: bind(age) { .date(on, op, age: $0, day: day) }) {
                    ForEach(SmartNotebookAge.allCases, id: \.self) { age in
                        Text(age.label).tag(age)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
        case .group:
            EmptyView()
        }
    }

    private func bind<T>(_ value: T, _ body: @escaping (T) -> SmartRule.Body) -> Binding<T> {
        Binding(get: { value }, set: { rule.body = body($0) })
    }
}

/// The rule's own type menu and the group's add menu offer the same list, so
/// picking a rule and changing one's mind read the same way.
struct SmartRuleTypeMenu: View {
    @Binding var rule: SmartRule

    var body: some View {
        Menu(rule.typeLabel) {
            SmartRuleTypeButtons(pick: become)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .fixedSize()
    }

    private func become(_ body: SmartRule.Body) {
        guard rule.typeLabel != SmartRule(body).typeLabel else { return }
        withAnimation(.snappy) { rule.body = body }
    }
}

struct SmartRuleAddMenu: View {
    let add: (SmartRule.Body) -> Void

    var body: some View {
        Menu {
            SmartRuleTypeButtons(pick: add)
            Divider()
            Button("Group of rules") { add(.group(.all, [])) }
        } label: {
            Label("Add rule", systemImage: "plus.circle.fill")
                .font(.callout)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

struct SmartRuleTypeButtons: View {
    let pick: (SmartRule.Body) -> Void

    var body: some View {
        ForEach(SmartTextField.allCases, id: \.self) { field in
            Button(field.label) { pick(.text(field, whole: false, exact: false, "")) }
        }
        Divider()
        Button("Kind") { pick(.kind(.any)) }
        Button("In") { pick(.folder("")) }
        Divider()
        ForEach(SmartDateField.allCases, id: \.self) { field in
            Button(field.label) { pick(.date(field, .within, age: .week, day: "")) }
        }
    }
}

extension SmartRule {
    var typeLabel: String {
        switch body {
        case let .text(field, _, _, _): field.label
        case .kind: "Kind"
        case .folder: "In"
        case let .date(field, _, _, _): field.label
        case .group: "Group"
        }
    }
}

struct RuleDeleteButton: View {
    let remove: () -> Void

    var body: some View {
        Button(action: remove) {
            Image(systemName: "minus.circle.fill")
                .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .help("Remove")
    }
}

/// Groups are pink and rules are yellow, so a block is recognisable as one or
/// the other before you read it. Both are drawn as a filled box with a line
/// round it: the line is what says where a group ends and its neighbour
/// begins, which a wash on its own never managed.
private func ruleBox(_ fill: Color, _ stroke: Color, radius: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: radius)
        .fill(fill)
        .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(stroke))
}

private let groupFill = Color.pink.opacity(0.07)
private let groupStroke = Color.pink.opacity(0.35)
private let rowFill = Color.yellow.opacity(0.16)
private let rowStroke = Color.orange.opacity(0.30)

func smartNotebook(
    id: String,
    name: String,
    root: SmartRule,
    showCount: Bool,
    notifyOnChange: Bool
) -> SmartNotebook {
    let flat = smartNotebookProjection(root)
    return SmartNotebook(
        id: id,
        name: name,
        query: flat.query,
        kind: flat.kind,
        scope: flat.scope,
        withinDays: flat.withinDays,
        showCount: showCount,
        notifyOnChange: notifyOnChange,
        rules: encodeSmartRules(root)
    )
}

func newSmartNotebook(query: String = "", scope: String = "") -> SmartNotebook {
    var rules: [SmartRule] = []
    if !query.isEmpty { rules.append(.text(query)) }
    if !scope.isEmpty { rules.append(SmartRule(.folder(scope))) }
    return smartNotebook(
        id: UUID().uuidString,
        name: query.isEmpty ? "" : query,
        root: .group(.all, rules),
        showCount: true,
        notifyOnChange: false
    )
}
