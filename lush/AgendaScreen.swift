import SwiftUI
import EventKit

struct AgendaScreen: View {
    let open: (String) -> Void

    @Environment(NotesModel.self) private var model
    @Environment(ContextTracker.self) private var contextTracker
    @State private var agenda = AgendaStore.shared
    @State private var noteUrls: [String: String] = [:]
    @State private var dayGroups: [DayGroup] = []
    @State private var highlighted: String?
    @State private var highlightTask: Task<Void, Never>?
    @State private var ready = false
    @State private var extendingBack = false

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
        .onChange(of: agenda.items, initial: true) { regroup() }
        .onChange(of: agenda.horizon) { regroup() }
    }

    private func regroup() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let first = calendar.date(byAdding: .day, value: -agenda.backHorizon, to: today) ?? today
        dayGroups = Agenda
            .days(agenda.items, from: first, count: agenda.backHorizon + agenda.horizon)
            .map(DayGroup.init)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Each day is a Section: a lazy stack tracks its children
                // through those, and a loose header plus a nested ForEach left
                // it dropping rows until they were scrolled well past.
                LazyVStack(alignment: .leading, spacing: 0) {
                    // Reaching the top of the list loads the previous
                    // fortnight. Keying the sentinel to the horizon makes each
                    // extension a fresh view, so its onAppear fires again when
                    // she scrolls up to the new top.
                    Color.clear
                        .frame(height: 1)
                        .id("back-\(agenda.backHorizon)")
                        .onAppear { extendBack(proxy) }
                    ForEach(dayGroups) { group in
                        Section {
                            // An event running over several days appears in
                            // each of them, so the day has to be part of the
                            // identity — one lazy stack holding the same id
                            // twice draws it once and leaves a hole.
                            ForEach(group.rows) { entry in
                                row(entry.item)
                            }
                        } header: {
                            header(group.day)
                                .id(group.day)
                                // The last header to scroll past the top is
                                // where she was; a lazy stack only builds those
                                // as they come into view, which is the signal.
                                .onAppear { agenda.restoreDay = group.day }
                        }
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("forward-\(agenda.horizon)")
                        .onAppear { Task { await agenda.extendHorizon() } }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 40)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .scrollIndicators(.hidden)
            .onAppear { settle(proxy) }
            .onChange(of: dayGroups.isEmpty) { settle(proxy) }
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


    /// The list now opens with a fortnight of the past above today, so today
    /// has to be scrolled to rather than simply being the top. Until that
    /// scroll has landed the back sentinel is ignored — it is visible at first
    /// layout, and extending then would drag the view into the past.
    private func settle(_ proxy: ScrollViewProxy) {
        guard !ready, !dayGroups.isEmpty else { return }
        if agenda.focusDay == nil {
            proxy.scrollTo(agenda.restoreDay ?? Calendar.current.startOfDay(for: Date()), anchor: .top)
        }
        Task { ready = true }
    }

    /// The day that was first stays put: it was at the top of the viewport
    /// when the sentinel appeared, and pinning it back there after the prepend
    /// is what keeps the list from jumping.
    private func extendBack(_ proxy: ScrollViewProxy) {
        guard ready, !extendingBack, let anchor = dayGroups.first?.day else { return }
        extendingBack = true
        Task {
            await agenda.extendBack()
            regroup()
            proxy.scrollTo(anchor, anchor: .top)
            extendingBack = false
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

    private func row(_ item: AgendaItem) -> some View {
        AgendaRow(
            item: item,
            noteUrl: noteUrls[item.id] ?? item.seriesId.flatMap { noteUrls[$0] },
            hasSeriesNote: noteUrls[item.seriesId ?? ""] != nil,
            highlighted: highlighted == item.id,
            open: open,
            create: create
        )
    }

    private func create(_ item: AgendaItem, series: Bool = false) {
        Task {
            contextTracker.start()
            if let url = await model.createNote(for: item, series: series, snap: contextTracker.snapshot) {
                open(url)
            }
        }
    }
}

struct DayGroup: Identifiable {
    let day: Date
    let rows: [Row]
    var id: Date { day }

    struct Row: Identifiable {
        let id: String
        let item: AgendaItem
    }

    init(_ group: (day: Date, items: [AgendaItem])) {
        day = group.day
        rows = group.items.map {
            Row(id: "\(group.day.timeIntervalSince1970)|\($0.rowKey)", item: $0)
        }
    }
}

private struct AgendaRow: View {
    let item: AgendaItem
    let noteUrl: String?
    let hasSeriesNote: Bool
    let highlighted: Bool
    let open: (String) -> Void
    let create: (AgendaItem, Bool) -> Void

    @Environment(NotesModel.self) private var model
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
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
            Button {
                item.openExternally()
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
                .strokeBorder(item.color, lineWidth: highlighted ? 2 : 0)
        )
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        #if os(macOS)
        .pointerStyle(.link)
        #endif
        .onTapGesture { openOrCreate() }
        .contextMenu {
            if let noteUrl {
                Button("Open Note") { open(noteUrl) }
                Button("Copy Note URL") { Clipboard.copy(noteUrl) }
                Button("New Note") { create(item, false) }
                if item.isRecurring, !hasSeriesNote {
                    Button("New Note for the Whole Series") { create(item, true) }
                }
                Divider()
                Button("Delete Note", role: .destructive) { model.deleteNote(noteUrl) }
            } else {
                Button("New Note") { create(item, false) }
                if item.isRecurring {
                    Button("New Note for the Whole Series") { create(item, true) }
                }
            }
            Divider()
            Button(item.kind == .reminder ? "Open in Reminders" : "Open in Calendar") {
                item.openExternally()
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

    private func openOrCreate() {
        if let url = model.noteUrl(for: item) {
            open(url)
        } else {
            create(item, false)
        }
    }
}
