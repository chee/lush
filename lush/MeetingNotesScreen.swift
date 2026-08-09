import SwiftUI

/// Notes written about calendar items that have already happened. The links
/// carry the occurrence they were taken at, so this reads straight off them
/// without asking EventKit for events long out of the agenda's window.
struct MeetingNotesScreen: View {
    let open: (String) -> Void

    @Environment(NotesModel.self) private var model
    @State private var entries: [Entry] = []

    struct Entry: Identifiable {
        var id: String { node.url }
        let node: FolderNode
        let when: Date
    }

    var body: some View {
        Group {
            if entries.isEmpty {
                ContentUnavailableView(
                    "No Meeting Notes",
                    systemImage: "doc.richtext",
                    description: Text("Notes about past events show up here.")
                )
            } else {
                list
            }
        }
        .navigationTitle("Meeting Notes")
        .task { reload() }
        .onReceive(NotificationCenter.default.publisher(for: CalendarLinks.changed)) { _ in
            reload()
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(grouped), id: \.day) { group in
                    Section {
                        ForEach(group.entries) { entry in
                            row(entry)
                        }
                    } header: {
                        Text(group.day.formatted(.dateTime.weekday(.wide).day().month(.wide).year()))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 26)
                            .padding(.bottom, 6)
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 40)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var grouped: [(day: Date, entries: [Entry])] {
        let calendar = Calendar.current
        var order: [Date] = []
        var byDay: [Date: [Entry]] = [:]
        for entry in entries {
            let day = calendar.startOfDay(for: entry.when)
            if byDay[day] == nil { order.append(day) }
            byDay[day, default: []].append(entry)
        }
        return order.map { ($0, byDay[$0] ?? []) }
    }

    private func row(_ entry: Entry) -> some View {
        NoteRowView(node: entry.node, showFolder: true)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .onTapGesture { open(entry.node.url) }
            .contextMenu { NoteContextMenu(node: entry.node) }
            #if os(macOS)
            .pointerStyle(.link)
            #endif
    }

    /// Newest first: what happened most recently is what she is looking for.
    /// A note kept for a whole series is linked to every occurrence of it, so
    /// it appears once, under the last one that has been and gone.
    private func reload() {
        let now = Date()
        var latest: [String: Date] = [:]
        for (itemId, url) in CalendarLinks.noteUrlByItem {
            guard let when = Agenda.eventKey(itemId).occurrence, when < now else { continue }
            if let existing = latest[url], existing >= when { continue }
            latest[url] = when
        }
        entries = latest
            .compactMap { url, when in
                model.node(for: url).map { Entry(node: $0, when: when) }
            }
            .sorted { $0.when > $1.when }
    }
}
