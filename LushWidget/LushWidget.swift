//
//  LushWidget.swift
//  LushWidget
//
//  Created by chee on 2026-08-04.
//

import WidgetKit
import SwiftUI
import AppIntents

private enum LushWidgetURL {
    static func folder(_ url: String?) -> URL {
        var components = URLComponents()
        components.scheme = "lush"
        components.host = "folder"
        if let url {
            components.queryItems = [URLQueryItem(name: "url", value: url)]
        }
        return components.url ?? URL(fileURLWithPath: "/")
    }

    static func note(_ url: String) -> URL {
        var components = URLComponents()
        components.scheme = "lush"
        components.host = "show"
        components.queryItems = [URLQueryItem(name: "doc", value: url)]
        return components.url ?? URL(fileURLWithPath: "/")
    }

    static var newNote: URL {
        var components = URLComponents()
        components.scheme = "lush"
        components.host = "new"
        return components.url ?? URL(fileURLWithPath: "/")
    }

    static var quickNote: URL {
        var components = URLComponents()
        components.scheme = "lush"
        components.host = "show"
        components.queryItems = [URLQueryItem(name: "doc", value: "quick")]
        return components.url ?? URL(fileURLWithPath: "/")
    }
}

private enum LushWidgetStore {
    static let appGroupIdentifier = "group.party.chee.patchwork.lush"
    static let snapshotFileName = "LushWidgetSnapshot.json"

    static func snapshot() -> LushWidgetSnapshot? {
        guard let root = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else { return nil }

        let url = root.appendingPathComponent(snapshotFileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LushWidgetSnapshot.self, from: data)
    }
}

struct LushWidgetSnapshot: Codable {
    let updatedAt: Date
    let defaultFolderUrl: String?
    let folders: [LushWidgetFolderSnapshot]
}

struct LushWidgetFolderSnapshot: Codable {
    let url: String
    let title: String
    let path: String
    let totalItemCount: Int
    let items: [LushWidgetItemSnapshot]
}

struct LushWidgetItemSnapshot: Codable {
    let url: String
    let title: String
    let preview: String
    let kind: String
}

struct LushWidgetFolderEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Lush Folder")
    static let defaultQuery = LushWidgetFolderQuery()

    let id: String
    let title: String
    let path: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(path)")
    }
}

struct LushWidgetFolderQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [LushWidgetFolderEntity] {
        let all = Self.entitiesFromSnapshot()
        return identifiers.compactMap { identifier in
            all.first(where: { $0.id == identifier }) ?? LushWidgetFolderEntity(
                id: identifier,
                title: "Folder",
                path: identifier
            )
        }
    }

    func entities(matching string: String) async throws -> [LushWidgetFolderEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return Self.entitiesFromSnapshot() }
        return Self.entitiesFromSnapshot().filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.path.localizedCaseInsensitiveContains(query)
                || $0.id.localizedCaseInsensitiveContains(query)
        }
    }

    func suggestedEntities() async throws -> [LushWidgetFolderEntity] {
        Self.entitiesFromSnapshot()
    }

    private static func entitiesFromSnapshot() -> [LushWidgetFolderEntity] {
        guard let snapshot = LushWidgetStore.snapshot() else { return [] }
        return snapshot.folders.map {
            LushWidgetFolderEntity(id: $0.url, title: $0.title, path: $0.path)
        }
    }
}

struct FolderWidgetConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Folder"
    static let description = IntentDescription("Choose the Lush folder to show.")

    @Parameter(title: "Folder")
    var folder: LushWidgetFolderEntity?
}

struct FolderContentEntry: TimelineEntry {
    let date: Date
    let folder: LushWidgetFolderSnapshot?
    let updatedAt: Date?
}

struct FolderContentProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> FolderContentEntry {
        FolderContentEntry(
            date: Date(),
            folder: LushWidgetFolderSnapshot(
                url: "",
                title: "Notes",
                path: "Notes",
                totalItemCount: 3,
                items: [
                    LushWidgetItemSnapshot(url: "", title: "Meeting notes", preview: "Agenda and follow-ups", kind: "rich"),
                    LushWidgetItemSnapshot(url: "", title: "Draft", preview: "Opening paragraph", kind: "rich"),
                    LushWidgetItemSnapshot(url: "", title: "Links", preview: "References to read", kind: "rich")
                ]
            ),
            updatedAt: Date()
        )
    }

    func snapshot(for configuration: FolderWidgetConfiguration, in context: Context) async -> FolderContentEntry {
        entry(for: configuration)
    }

    func timeline(for configuration: FolderWidgetConfiguration, in context: Context) async -> Timeline<FolderContentEntry> {
        Timeline(entries: [entry(for: configuration)], policy: .after(Date().addingTimeInterval(30 * 60)))
    }

    private func entry(for configuration: FolderWidgetConfiguration) -> FolderContentEntry {
        let snapshot = LushWidgetStore.snapshot()
        let folder = snapshot.flatMap { snapshot in
            if let configured = configuration.folder?.id {
                return snapshot.folders.first { $0.url == configured }
            }
            if let defaultFolderUrl = snapshot.defaultFolderUrl {
                return snapshot.folders.first { $0.url == defaultFolderUrl }
            }
            return snapshot.folders.first
        }
        return FolderContentEntry(date: Date(), folder: folder, updatedAt: snapshot?.updatedAt)
    }
}

struct FolderContentWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: FolderContentEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let folder = entry.folder {
                if folder.items.isEmpty {
                    emptyState
                } else {
                    VStack(alignment: .leading, spacing: family == .systemSmall ? 5 : 7) {
                        ForEach(Array(folder.items.prefix(itemLimit)), id: \.url) { item in
                            itemRow(item)
                        }
                    }
                }
            } else {
                setupState
            }
            Spacer(minLength: 0)
        }
        .containerBackground(.background, for: .widget)
        .widgetURL(LushWidgetURL.folder(entry.folder?.url))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "folder")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tint)
            Text(entry.folder?.title ?? "Lush")
                .font(.headline.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 0)
            if let count = entry.folder?.totalItemCount {
                Text(count, format: .number)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private var emptyState: some View {
        Label("Empty folder", systemImage: "tray")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private var setupState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Open Lush")
                .font(.subheadline.weight(.semibold))
            Text("Folder content appears after the app refreshes.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
    }

    private var itemLimit: Int {
        switch family {
        case .systemLarge:
            6
        case .systemMedium:
            4
        default:
            3
        }
    }

    private func itemRow(_ item: LushWidgetItemSnapshot) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: iconName(for: item.kind))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                if family != .systemSmall, !item.preview.isEmpty {
                    Text(item.preview)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private func iconName(for kind: String) -> String {
        switch kind {
        case "rich", "lush":
            "doc.text"
        default:
            "doc"
        }
    }
}

struct FolderContentWidget: Widget {
    let kind = "FolderContentWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: FolderWidgetConfiguration.self,
            provider: FolderContentProvider()
        ) { entry in
            FolderContentWidgetView(entry: entry)
        }
        .configurationDisplayName("Lush Folder")
        .description("Show recent content from a selected folder.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct NoteActionEntry: TimelineEntry {
    let date: Date
}

struct NoteActionProvider: TimelineProvider {
    func placeholder(in context: Context) -> NoteActionEntry {
        NoteActionEntry(date: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (NoteActionEntry) -> Void) {
        completion(NoteActionEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NoteActionEntry>) -> Void) {
        completion(Timeline(entries: [NoteActionEntry(date: Date())], policy: .never))
    }
}

struct QuickNoteWidgetView: View {
    var body: some View {
        Link(destination: LushWidgetURL.quickNote) {
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 3) {
                    Image(systemName: "bolt.fill")
                        .font(.title3.weight(.semibold))
                    Text("Quick")
                        .font(.caption2.weight(.medium))
                        .minimumScaleFactor(0.8)
                }
                .widgetAccentable()
            }
        }
    }
}

struct NewNoteWidgetView: View {
    var body: some View {
        Link(destination: LushWidgetURL.newNote) {
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil")
                    .font(.title3.weight(.semibold))
                VStack(alignment: .leading, spacing: 2) {
                    Text("New Note")
                        .font(.headline)
                    Text("Start writing")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .widgetAccentable()
        }
    }
}

struct QuickNoteLockScreenWidget: Widget {
    let kind = "LushWidget"

    private static var supportedFamilies: [WidgetFamily] {
        #if os(iOS)
        [.accessoryCircular]
        #else
        [.systemSmall]
        #endif
    }

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NoteActionProvider()) { _ in
            QuickNoteWidgetView()
        }
        .configurationDisplayName("Quick Note")
        .description("Open your Quick Note from the Lock Screen.")
        .supportedFamilies(Self.supportedFamilies)
    }
}

struct NewNoteLockScreenWidget: Widget {
    let kind = "NewNoteLockScreenWidget"

    private static var supportedFamilies: [WidgetFamily] {
        #if os(iOS)
        [.accessoryRectangular]
        #else
        [.systemSmall]
        #endif
    }

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NoteActionProvider()) { _ in
            NewNoteWidgetView()
        }
        .configurationDisplayName("New Note")
        .description("Create a new note from the Lock Screen.")
        .supportedFamilies(Self.supportedFamilies)
    }
}

@available(iOS 18.0, macOS 15.0, *)
enum LushControlDestination: String, AppEnum {
    case quickNote
    case newNote

    static let typeDisplayRepresentation = TypeDisplayRepresentation("Lush destination")
    static let caseDisplayRepresentations: [LushControlDestination: DisplayRepresentation] = [
        .quickNote: "Quick Note",
        .newNote: "New Note"
    ]
}

@available(iOS 18.0, macOS 15.0, *)
struct OpenLushControlIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Lush"
    static let description = IntentDescription("Open Lush to a note action.")

    @Parameter(title: "Destination")
    var target: LushControlDestination

    init() {
        target = .quickNote
    }

    init(target: LushControlDestination) {
        self.target = target
    }

    // runs in the widget extension, so opening the app has to carry the
    // destination through a routed url rather than AppRouter state
    func perform() async throws -> some IntentResult & OpensIntent {
        let destination: URL = switch target {
        case .quickNote: LushWidgetURL.quickNote
        case .newNote: LushWidgetURL.newNote
        }
        return .result(opensIntent: OpenURLIntent(destination))
    }
}

@available(iOS 18.0, macOS 15.0, *)
struct QuickNoteControlWidget: ControlWidget {
    let kind = "QuickNoteControlWidget"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: kind) {
            ControlWidgetButton(action: OpenLushControlIntent(target: .quickNote)) {
                Label("Quick Note", systemImage: "bolt.fill")
            }
        }
        .displayName("Quick Note")
        .description("Open your Quick Note from Control Center.")
    }
}

@available(iOS 18.0, macOS 15.0, *)
struct NewNoteControlWidget: ControlWidget {
    let kind = "NewNoteControlWidget"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: kind) {
            ControlWidgetButton(action: OpenLushControlIntent(target: .newNote)) {
                Label("New Note", systemImage: "square.and.pencil")
            }
        }
        .displayName("New Note")
        .description("Create a new note from Control Center.")
    }
}

#if os(iOS)
#Preview("Quick Note", as: .accessoryCircular) {
    QuickNoteLockScreenWidget()
} timeline: {
    NoteActionEntry(date: .now)
}

#Preview("New Note", as: .accessoryRectangular) {
    NewNoteLockScreenWidget()
} timeline: {
    NoteActionEntry(date: .now)
}

#Preview("Folder", as: .systemMedium) {
    FolderContentWidget()
} timeline: {
    FolderContentEntry(
        date: .now,
        folder: LushWidgetFolderSnapshot(
            url: "automerge:preview",
            title: "Inbox",
            path: "Inbox",
            totalItemCount: 3,
            items: [
                LushWidgetItemSnapshot(url: "1", title: "Trip ideas", preview: "Cafe, train, packing list", kind: "rich"),
                LushWidgetItemSnapshot(url: "2", title: "Reading", preview: "Papers to skim", kind: "rich"),
                LushWidgetItemSnapshot(url: "3", title: "Sketch", preview: "", kind: "file")
            ]
        ),
        updatedAt: .now
    )
}
#endif

struct LaunchEntry: TimelineEntry {
    let date = Date()
}

struct LaunchProvider: TimelineProvider {
    func placeholder(in context: Context) -> LaunchEntry {
        LaunchEntry()
    }

    func getSnapshot(in context: Context, completion: @escaping (LaunchEntry) -> Void) {
        completion(LaunchEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LaunchEntry>) -> Void) {
        completion(Timeline(entries: [LaunchEntry()], policy: .never))
    }
}

struct LaunchWidgetView: View {
    let symbol: String
    let title: String
    let url: URL

    @Environment(\.widgetFamily) private var family

    private var fullLabel: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.title)
            Text(title)
                .font(.caption.weight(.medium))
        }
    }

    var body: some View {
        Group {
            #if os(iOS)
            if family == .accessoryCircular {
                Image(systemName: symbol)
                    .font(.title2)
            } else {
                fullLabel
            }
            #else
            fullLabel
            #endif
        }
        .widgetURL(url)
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct NewNoteWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "party.chee.lush.new-note", provider: LaunchProvider()) { _ in
            LaunchWidgetView(
                symbol: "square.and.pencil",
                title: "New Note",
                url: LushWidgetURL.newNote
            )
        }
        .configurationDisplayName("New Note")
        .description("Start a new note.")
        #if os(iOS)
        .supportedFamilies([.systemSmall, .accessoryCircular])
        #else
        .supportedFamilies([.systemSmall])
        #endif
    }
}

struct QuickNoteWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "party.chee.lush.quick-note", provider: LaunchProvider()) { _ in
            LaunchWidgetView(
                symbol: "bolt.circle",
                title: "Quick Note",
                url: LushWidgetURL.quickNote
            )
        }
        .configurationDisplayName("Quick Note")
        .description("Open your Quick Note.")
        #if os(iOS)
        .supportedFamilies([.systemSmall, .accessoryCircular])
        #else
        .supportedFamilies([.systemSmall])
        #endif
    }
}
