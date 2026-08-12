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
    @State private var position = ScrollPosition(
        id: AgendaStore.shared.restoreDay ?? Calendar.current.startOfDay(for: Date()),
        anchor: .top
    )
    @State private var settled = false
    @State private var extending = false

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
            } else if agenda.items.isEmpty, agenda.isFreshWindow {
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
            if agenda.focusDay == nil, agenda.restoreDay == nil { agenda.resetWindow() }
            await agenda.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: CalendarLinks.changed)) { _ in
            noteUrls = CalendarLinks.noteUrlByItem
        }
        .onChange(of: agenda.items, initial: true) { regroup() }
    }

    private func regroup() {
        dayGroups = Agenda
            .days(agenda.items, from: agenda.windowStart, count: agenda.windowDayCount)
            .map(DayGroup.init)
    }

    private var list: some View {
        ScrollView {
            // Each day is one child of the lazy stack — a loose header plus a
            // nested ForEach left it dropping rows until they were scrolled
            // well past, and a single view per day also gives the scroll
            // target layout one date to anchor by.
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(dayGroups) { group in
                    VStack(alignment: .leading, spacing: 0) {
                        header(group.day)
                        // An event running over several days appears in each
                        // of them, so the day has to be part of the identity —
                        // one lazy stack holding the same id twice draws it
                        // once and leaves a hole.
                        ForEach(group.rows) { entry in
                            row(entry.item)
                        }
                    }
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 28)
            .padding(.bottom, 40)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .scrollPosition($position, anchor: .top)
        // The toolbar floats over the top of the scroll content, so a day
        // anchored to the bare container edge lands tucked underneath it.
        // A top content margin moves the resting edge down for every anchor —
        // the seeded open, the settle assert, a focus jump — while costing
        // nothing mid-scroll: it is the container's edge, not the cells'.
        .contentMargins(.top, 40, for: .scrollContent)
        .scrollIndicators(.hidden)
        // The scroll geometry drives the sliding window: nearing either end
        // extends it, and the position binding keeps the day she is looking
        // at where it is while days are spliced in and out of the far ends —
        // no sentinel views, nothing to get stuck on at the very top.
        .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { old, new in
            slide(from: old, to: new)
        }
        .onChange(of: dayGroups.isEmpty, initial: true) { settle() }
        .onChange(of: agenda.focusDay, initial: true) { focusChanged() }
    }

    /// Opens anchored on today — or, coming back, on the day she left at,
    /// which the store remembers along with the loaded window. The position
    /// is seeded before anything renders and asserted again in the update the
    /// first day groups land — the binding resolves a day id through the
    /// target layout without the day having to be built, so there is no race
    /// against lazy layout.
    private func settle() {
        guard !settled, !dayGroups.isEmpty else { return }
        settled = true
        guard agenda.focusDay == nil else { return }
        position.scrollTo(
            id: agenda.restoreDay ?? Calendar.current.startOfDay(for: Date()),
            anchor: .top
        )
    }

    private func focusChanged() {
        guard let day = agenda.focusDay else { return }
        agenda.focusDay = nil
        let item = agenda.focusItem
        agenda.focusItem = nil
        Task {
            await agenda.ensureWindow(around: day)
            regroup()
            withAnimation { position.scrollTo(id: day, anchor: .top) }
            guard let item else { return }
            withAnimation { highlighted = item }
            highlightTask?.cancel()
            highlightTask = Task {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                withAnimation { highlighted = nil }
            }
        }
    }

    /// Extension is asked for two screens before either edge and only while
    /// actually scrolling toward it, so the splice happens out of sight and a
    /// flick that reaches the very top still recovers — the trigger is the
    /// geometry, not a view that has to reappear. The forward edge also
    /// extends when new content still doesn't fill the viewport.
    private func slide(from old: ScrollGeometry, to new: ScrollGeometry) {
        guard settled, !extending, !dayGroups.isEmpty else { return }
        // The day at the top of the viewport, straight from the position
        // binding, is where she is — kept in the store so leaving and coming
        // back returns here rather than to today.
        if let day = position.viewID(type: Date.self) {
            agenda.restoreDay = day
        }
        let margin = new.containerSize.height * 2
        let top = new.contentOffset.y + new.contentInsets.top
        let oldTop = old.contentOffset.y + old.contentInsets.top
        let bottom = new.contentSize.height - new.containerSize.height - new.contentOffset.y
        let oldBottom = old.contentSize.height - old.containerSize.height - old.contentOffset.y
        if top < margin, top < oldTop {
            extend { await agenda.extendBack() }
        } else if bottom < margin, bottom < oldBottom || new.contentSize.height != old.contentSize.height {
            extend { await agenda.extendHorizon() }
        }
    }

    private func extend(_ work: @escaping () async -> Void) {
        extending = true
        Task {
            await work()
            regroup()
            extending = false
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
