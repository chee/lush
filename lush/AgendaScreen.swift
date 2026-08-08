import SwiftUI
import EventKit

struct AgendaScreen: View {
    let open: (String) -> Void

    @Environment(NotesModel.self) private var model
    @Environment(ContextTracker.self) private var contextTracker
    @State private var agenda = AgendaStore.shared
    @State private var links = 0
    @State private var hovered: String?

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
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Agenda.days(agenda.items), id: \.day) { group in
                    header(group.day)
                    ForEach(group.items) { item in
                        row(item, on: group.day)
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 40)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .id(links)
    }

    private func header(_ day: Date) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(Calendar.current.component(.day, from: day))")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(.primary)
            Text(Agenda.dayName(day))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)
            VStack { Divider() }
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 13 }
        }
        .padding(.top, 34)
        .padding(.bottom, 10)
    }

    private func row(_ item: AgendaItem, on day: Date) -> some View {
        let noteUrl = model.noteUrl(for: item)
        let key = "\(day.timeIntervalSince1970)|\(item.id)"
        let hovering = hovered == key
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let time = item.timeText {
                Text(time)
                    .font(.system(size: 15).monospacedDigit())
                    .foregroundStyle(item.color)
            } else {
                Capsule()
                    .fill(item.color)
                    .frame(width: 3, height: 14)
            }
            if item.kind == .reminder {
                Image(systemName: "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(item.color)
            }
            Text(item.title)
                .font(.system(size: 16))
                .underline(hovering)
                .lineLimit(1)
            if noteUrl != nil {
                Image(systemName: "doc.richtext")
                    .font(.system(size: 12))
                    .foregroundStyle(.tint)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { inside in
            hovered = inside ? key : (hovered == key ? nil : hovered)
        }
        #if os(macOS)
        .pointerStyle(.link)
        #endif
        .onTapGesture { openOrCreate(item) }
        .contextMenu {
            if let noteUrl {
                Button("Open Note") { open(noteUrl) }
                Button("Copy Note URL") { Clipboard.copy(noteUrl) }
                Button("New Note") { create(item) }
                Divider()
                Button("Delete Note", role: .destructive) { model.deleteNote(noteUrl) }
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
