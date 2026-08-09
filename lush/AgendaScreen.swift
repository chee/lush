import SwiftUI
import EventKit

struct AgendaScreen: View {
    let open: (String) -> Void

    @Environment(NotesModel.self) private var model
    @Environment(ContextTracker.self) private var contextTracker
    @State private var agenda = AgendaStore.shared
    @State private var noteUrls: [String: String] = [:]
    @State private var hovered: String?
    @State private var highlighted: String?
    @State private var highlightTask: Task<Void, Never>?

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
        .task {
            noteUrls = CalendarLinks.noteUrlByItem
            await agenda.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: CalendarLinks.changed)) { _ in
            noteUrls = CalendarLinks.noteUrlByItem
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Agenda.days(agenda.items), id: \.day) { group in
                        header(group.day)
                            .id(group.day)
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
            .onChange(of: agenda.focusDay, initial: true) {
                guard let day = agenda.focusDay else { return }
                withAnimation { proxy.scrollTo(day, anchor: .top) }
                agenda.focusDay = nil
                guard let item = agenda.focusItem else { return }
                agenda.focusItem = nil
                withAnimation { highlighted = item }
                highlightTask?.cancel()
                highlightTask = Task {
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled else { return }
                    withAnimation { highlighted = nil }
                }
            }
        }
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
        let noteUrl = noteUrls[item.id]
        let key = "\(day.timeIntervalSince1970)|\(item.id)"
        let hovering = hovered == key
        return HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(item.title)
                        .font(.system(size: 15, weight: .semibold))
                        .underline(hovering)
                        .lineLimit(1)
                    if noteUrl != nil {
                        Image(systemName: "doc.richtext")
                            .font(.system(size: 12))
                    }
                }
                HStack(spacing: 4) {
                    Image(systemName: item.kind == .reminder ? "checklist" : "clock")
                    Text(item.rangeText)
                    if let location = item.location {
                        Image(systemName: "mappin.and.ellipse")
                            .padding(.leading, 4)
                        Text(location).lineLimit(1)
                    }
                    if !item.listName.isEmpty {
                        Text("· \(item.listName)").lineLimit(1)
                    }
                }
                .font(.system(size: 12))
                .opacity(0.75)
            }
            Spacer(minLength: 8)
            if let url = item.calendarAppURL {
                Button {
                    ExternalBrowser.open(url)
                } label: {
                    Image(systemName: "arrow.up.forward")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(item.color.opacity(0.45))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .strokeBorder(item.color.opacity(0.6), lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(item.kind == .reminder ? "Open in Reminders" : "Open in Calendar")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .foregroundStyle(item.color.mix(with: .primary, by: 0.65))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(item.color.opacity(hovering ? 0.38 : 0.28))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(item.color, lineWidth: highlighted == item.id ? 2 : 0)
        )
        .padding(.vertical, 3)
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
            if let url = item.calendarAppURL {
                Divider()
                Button("Open in Calendar") { ExternalBrowser.open(url) }
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
