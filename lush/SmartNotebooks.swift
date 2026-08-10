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
            guard !Task.isCancelled, let self, self.startupSettled else { return }
            let hits = await self.smartNotebookHits(folder)
            guard !Task.isCancelled else { return }
            self.smartHits[folder.id] = hits
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
    /// Set when the editor is the detail pane rather than a sheet: there is no
    /// sheet to dismiss, so the caller takes it down.
    var close: (() -> Void)?
    @Environment(NotesModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var root = SmartRule.group(.all, [])
    @State private var showCount = true
    @State private var notifyOnChange = false
    @State private var notificationsDenied = false
    @State private var loaded = false
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        form
            .navigationTitle(isNew ? "New Smart Notebook" : "Smart Notebook")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { saveAndClose() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                name = existing.name
                root = existing.rootRule
                showCount = existing.showCount
                notifyOnChange = existing.notifyOnChange
                loaded = true
            }
            .onChange(of: name) { scheduleSave() }
            .onChange(of: root) { scheduleSave() }
            .onChange(of: showCount) { scheduleSave() }
            .onChange(of: notifyOnChange) {
                scheduleSave()
                if notifyOnChange {
                    Task { notificationsDenied = await !SmartNotebookAlerts.requestAuthorization() }
                }
            }
            .onDisappear {
                saveTask?.cancel()
                saveNow()
            }
    }

    @ViewBuilder private var form: some View {
        if close == nil {
            NavigationStack { fields }
            #if os(macOS)
                .frame(minWidth: 620, minHeight: 460)
            #endif
        } else {
            fields
        }
    }

    private var fields: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                TextField("Untitled", text: $name)
                    .textFieldStyle(.plain)
                    .labelsHidden()
                    .font(Font(EditorSettings.font(ofSize: EditorSettings.bodySize + 10, weight: .bold)))
                SmartRuleGroup(rule: $root, depth: 0, move: move)
                Text(
                    "“Contains” is loose: it ignores case and accents, and a Note rule also "
                        + "finds notes that mean the same thing without saying it. "
                        + "“Exactly” matches the characters as typed. Use created:, changed:, "
                        + "weather:, location:, has:, tag:, title:, kind:, or when: inside a Note rule. "
                        + "Dates accept today, yesterday, YYYY-MM-DD, <, and >."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                settings
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Show count", isOn: $showCount)
            Toggle("Notify when count changes", isOn: $notifyOnChange)
            if notificationsDenied {
                Text("Notifications are turned off for Lush in System Settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
    }

    /// A dragged rule leaves where it was and lands where it was dropped. A
    /// group dropped inside itself would take the tree with it, so it stays.
    private func move(_ id: UUID, into group: UUID, at index: Int) {
        guard let dragged = root.node(id), dragged.node(group) == nil else { return }
        guard let from = root.parent(of: id) else { return }
        var next = root
        next.drop(id)
        next.insert(dragged, into: group, at: from.group == group && from.index < index ? index - 1 : index)
        withAnimation(.snappy) { root = next }
    }

    private func dismissEditor() {
        if let close { close() } else { dismiss() }
    }

    private func scheduleSave() {
        guard loaded else { return }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    private func saveNow() {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard loaded, !name.isEmpty else { return }
        model.saveSmartNotebook(
            smartNotebook(
                id: existing.id,
                name: name,
                root: root,
                showCount: showCount,
                notifyOnChange: notifyOnChange
            )
        )
    }

    private func saveAndClose() {
        saveTask?.cancel()
        saveNow()
        dismissEditor()
    }
}

/// A block of rules, laid out the way Shortcuts lays out a nested if: every
/// row is a pill, a level in steps the left edge over, and the right edge
/// stays where it is. Nothing is drawn round a group — the indent is the
/// grouping, and the group's own "Add rule" marks where it ends.
struct SmartRuleGroup: View {
    @Binding var rule: SmartRule
    let depth: Int
    let move: (UUID, UUID, Int) -> Void
    var remove: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
                RuleDeleteButton(remove: remove)
                    .opacity(hovering ? 1 : 0)
            }
            .font(.callout.weight(.medium))
            .rulePill(groupTint)
            .draggable(rule.id.uuidString)
            .ruleDropTarget(group: rule.id, index: 0, move: move)
            .padding(.leading, ruleIndent * CGFloat(depth))
            .onHover { hovering = $0 }
            ForEach(Array($rule.children.enumerated()), id: \.element.id) { index, $child in
                RuleDropSlot(group: rule.id, index: index, move: move)
                    .padding(.leading, ruleIndent * CGFloat(depth + 1))
                if child.isGroup {
                    SmartRuleGroup(
                        rule: $child,
                        depth: depth + 1,
                        move: move,
                        remove: { drop(child.id) }
                    )
                } else {
                    SmartRuleRow(rule: $child, remove: { drop(child.id) })
                        .ruleDropTarget(group: rule.id, index: index + 1, move: move)
                        .padding(.leading, ruleIndent * CGFloat(depth + 1))
                }
            }
            RuleDropSlot(group: rule.id, index: rule.children.count, move: move)
                .padding(.leading, ruleIndent * CGFloat(depth + 1))
            SmartRuleAddMenu(add: add)
                .padding(.top, 4)
                .padding(.leading, ruleIndent * CGFloat(depth + 1) + 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func add(_ body: SmartRule.Body) {
        withAnimation(.snappy) { rule.children.append(SmartRule(body)) }
    }

    private func drop(_ id: UUID) {
        withAnimation(.snappy) { rule.children.removeAll { $0.id == id } }
    }
}

/// The gap between two rules, and where a dragged one goes. The gap is there
/// either way; it only shows itself when something is over it.
struct RuleDropSlot: View {
    let group: UUID
    let index: Int
    let move: (UUID, UUID, Int) -> Void
    @State private var targeted = false

    var body: some View {
        Color.clear
            .frame(height: 10)
            .overlay {
                Capsule()
                    .fill(targeted ? Color.accentColor : .clear)
                    .frame(height: 3)
            }
            .contentShape(Rectangle())
            .dropDestination(for: String.self) { items, _ in
                guard let id = items.first.flatMap({ UUID(uuidString: $0) }) else { return false }
                move(id, group, index)
                return true
            } isTargeted: { targeted = $0 }
    }
}

/// A pill takes a drop too, not only the gaps: landing on one puts the dragged
/// rule just after it, and landing on a group's header puts it inside.
private struct RuleDropTarget: ViewModifier {
    let group: UUID
    let index: Int
    let move: (UUID, UUID, Int) -> Void
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, lineWidth: targeted ? 2 : 0)
            }
            .dropDestination(for: String.self) { items, _ in
                guard let id = items.first.flatMap({ UUID(uuidString: $0) }) else { return false }
                move(id, group, index)
                return true
            } isTargeted: { targeted = $0 }
    }
}

extension View {
    func ruleDropTarget(group: UUID, index: Int, move: @escaping (UUID, UUID, Int) -> Void) -> some View {
        modifier(RuleDropTarget(group: group, index: index, move: move))
    }
}

struct SmartRuleRow: View {
    @Binding var rule: SmartRule
    let remove: () -> Void
    @Environment(NotesModel.self) private var model
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            SmartRuleTypeMenu(rule: $rule)
            comparison
            Spacer(minLength: 12)
            value
                .layoutPriority(1)
            RuleDeleteButton(remove: remove)
                .opacity(hovering ? 1 : 0)
        }
        .font(.callout)
        .rulePill(rowTint)
        .draggable(rule.id.uuidString)
        .onHover { hovering = $0 }
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
            let text = bind(text) { .text(field, whole: whole, exact: exact, $0) }
            VStack(alignment: .leading, spacing: 6) {
                TextField("", text: text, prompt: Text("text to find"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(minWidth: 120, maxWidth: 260)
                if field == .anything, !SearchSyntax(text.wrappedValue).clauses.isEmpty {
                    SearchSyntaxPills(text: text)
                        .frame(maxWidth: 260)
                }
            }
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
    let remove: (() -> Void)?

    var body: some View {
        Button { remove?() } label: {
            Image(systemName: "minus.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .disabled(remove == nil)
        .help("Remove")
    }
}

private let ruleIndent: CGFloat = 18
private let groupTint = Color.yellow.opacity(0.22)
private let rowTint = Color.pink.opacity(0.14)

extension View {
    func rulePill(_ tint: Color) -> some View {
        padding(.vertical, 7)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint, in: RoundedRectangle(cornerRadius: 10))
    }
}

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
