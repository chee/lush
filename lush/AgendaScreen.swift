import SwiftUI
import EventKit

struct AgendaScreen: View {
    let open: (String) -> Void

    @Environment(NotesModel.self) private var model
    @Environment(ContextTracker.self) private var contextTracker
    @State private var agenda = AgendaStore.shared
    @State private var links = 0

    var body: some View {
        Group {
            if agenda.access != .fullAccess && agenda.reminderAccess != .fullAccess {
                ContentUnavailableView {
                    Label("Calendar Access", systemImage: "calendar.badge.exclamationmark")
                } description: {
                    Text("Lush shows your day once it can read your calendar and reminders.")
                } actions: {
                    Button("Allow Access") {
                        Task { await agenda.requestAccess() }
                    }
                }
            } else if agenda.items.isEmpty {
                ContentUnavailableView(
                    "Nothing Scheduled",
                    systemImage: "calendar",
                    description: Text("No events or reminders in the next two weeks.")
                )
            } else {
                list
            }
        }
        .navigationTitle("Calendar")
        .task { await agenda.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: CalendarLinks.changed)) { _ in
            links += 1
        }
    }

    private var list: some View {
        List {
            ForEach(Agenda.days(agenda.items), id: \.day) { group in
                Section {
                    ForEach(group.items) { item in
                        row(item)
                    }
                } header: {
                    header(group.day)
                }
            }
        }
        .listStyle(.plain)
        .id(links)
    }

    private func header(_ day: Date) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(Calendar.current.component(.day, from: day))")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.primary)
            Text(Agenda.dayName(day))
                .font(.headline)
                .foregroundStyle(.secondary)
            VStack { Divider() }
        }
        .padding(.top, 14)
        .padding(.bottom, 2)
        .textCase(nil)
    }

    private func row(_ item: AgendaItem) -> some View {
        let noteUrl = model.noteUrl(for: item)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Group {
                if let time = item.timeText {
                    Text(time)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(item.color)
                } else {
                    Capsule()
                        .fill(item.color)
                        .frame(width: 3, height: 12)
                }
            }
            .frame(width: 76, alignment: .trailing)
            if item.kind == .reminder {
                Image(systemName: "circle")
                    .font(.caption)
                    .foregroundStyle(item.color)
            }
            Text(item.title)
                .lineLimit(1)
            if noteUrl != nil {
                Image(systemName: "doc.richtext")
                    .font(.caption)
                    .foregroundStyle(.tint)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        #if os(macOS)
        .onTapGesture(count: 2) { openOrCreate(item) }
        #else
        .onTapGesture { openOrCreate(item) }
        #endif
        .contextMenu {
            if let noteUrl {
                Button("Open Note") { open(noteUrl) }
                Button("New Note") { create(item) }
                Button("Copy Note URL") { Clipboard.copy(noteUrl) }
            } else {
                Button("New Note") { create(item) }
            }
            if let location = item.location {
                Text(location)
            }
            if !item.listName.isEmpty {
                Text(item.listName)
            }
            Text(item.rangeText)
        }
    }

    private func openOrCreate(_ item: AgendaItem) {
        if let url = model.noteUrl(for: item) {
            open(url)
        } else {
            create(item)
        }
    }

    private func create(_ item: AgendaItem) {
        Task {
            if let url = await model.createNote(for: item, snap: contextTracker.snapshot) {
                open(url)
            }
        }
    }
}
