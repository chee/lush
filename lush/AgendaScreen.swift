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
    @State private var pendingAnchor: Date? = AgendaStore.shared.focusDay == nil
        ? AgendaStore.shared.restoreDay ?? Calendar.current.startOfDay(for: Date())
        : nil
    @State private var settled = false
    @State private var extending = false
    @State private var assertedSize: CGFloat?
    @State private var assertedAt = Date.distantPast
    @State private var scroller: ScrollViewProxy?
    @State private var visibleDays: Set<Date> = []

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
        ScrollViewReader { proxy in
            scrollView(proxy)
        }
    }

    private func scrollView(_ proxy: ScrollViewProxy) -> some View {
        ScrollView {
            // A plain stack, deliberately: the window never exceeds
            // Agenda.windowLimit days, so laziness buys nothing — and it cost
            // a lot. Lazily-built cells re-estimate their heights as they
            // come and go, which made the content size churn under the
            // scroll, and a day that wasn't built yet was a day the proxy
            // silently couldn't scroll to. Fully materialized, every anchor
            // resolves and the geometry stays put.
            VStack(alignment: .leading, spacing: 0) {
                ForEach(dayGroups) { group in
                    VStack(alignment: .leading, spacing: 0) {
                        // Inside the day cell, so each day stays one child
                        // with one date identity — anchoring and the window
                        // splices never have to know months exist.
                        if Calendar.current.component(.day, from: group.day) == 1 {
                            monthHeader(group.day)
                        }
                        header(group.day)
                        // An event running over several days appears in each
                        // of them, so the day has to be part of the identity —
                        // one lazy stack holding the same id twice draws it
                        // once and leaves a hole.
                        ForEach(group.rows) { entry in
                            row(entry.item)
                        }
                    }
                    .id(group.day)
                    // The topmost day actually on screen is where she is —
                    // kept in the store so leaving and coming back returns
                    // here rather than to today.
                    .onScrollVisibilityChange(threshold: 0.05) { visible in
                        if visible { visibleDays.insert(group.day) }
                        else { visibleDays.remove(group.day) }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 40)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .contentMargins(.top, 12, for: .scrollContent)
        .scrollIndicators(.hidden)
        .overlay(alignment: .top) {
            MonthChip(days: $visibleDays)
                .padding(.top, 6)
        }
        // The scroll geometry drives the sliding window: crossing into either
        // end extends it, and the anchor machinery pins the day she was on
        // while days are spliced in — no sentinel views, nothing to get
        // stuck on at the very top.
        .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { old, new in
            slide(from: old, to: new)
        }
        .onAppear { scroller = proxy }
        .onChange(of: agenda.focusDay, initial: true) { focusChanged() }
        .toolbar {
            ToolbarItem {
                Button("Today") {
                    agenda.restoreDay = nil
                    agenda.focusDay = Calendar.current.startOfDay(for: Date())
                }
            }
        }
    }

    /// Every landing — cold open, coming back, a link, the today button —
    /// funnels through here so they cannot drift apart. The scroll is asked
    /// for straight away, then re-asserted from the geometry callback each
    /// time layout changes underneath it, because a scroll-to issued in the
    /// same update as the content it targets is dropped. Once the offset
    /// moves without the layout changing it has landed — or she has taken
    /// over, which is just as final — and the window is free to slide.
    private func settle() {
        pendingAnchor = nil
        settled = true
        if let top = visibleDays.min() {
            agenda.restoreDay = top
        }
    }

    private func anchor(_ day: Date, animated: Bool = false) {
        pendingAnchor = day
        settled = false
        assertedSize = nil
        if animated {
            withAnimation { scroller?.scrollTo(day, anchor: .top) }
        } else {
            scroller?.scrollTo(day, anchor: .top)
        }
    }

    private func focusChanged() {
        guard let day = agenda.focusDay else { return }
        agenda.focusDay = nil
        let item = agenda.focusItem
        agenda.focusItem = nil
        Task {
            await agenda.ensureWindow(around: day)
            regroup()
            anchor(day, animated: true)
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
        guard new.containerSize.height > 100 else { return }
        if let day = pendingAnchor {
            if abs(new.contentOffset.y - old.contentOffset.y) > 8,
               new.contentSize.height == old.contentSize.height,
               Date.now.timeIntervalSince(assertedAt) > 0.6 {
                settle()
            } else if assertedSize != new.contentSize.height,
                      dayGroups.contains(where: { $0.day == day }) {
                assertedSize = new.contentSize.height
                assertedAt = Date.now
                Task { @MainActor in
                    guard pendingAnchor == day else { return }
                    scroller?.scrollTo(day, anchor: .top)
                    try? await Task.sleep(for: .seconds(1))
                    guard pendingAnchor == day,
                          Date.now.timeIntervalSince(assertedAt) >= 0.9 else { return }
                    settle()
                }
            }
            return
        }
        guard settled, !extending, !dayGroups.isEmpty else { return }
        // The topmost day on screen is where she is — recorded only on real
        // scroll ticks, so the teardown of a navigation pop can't smear it.
        if let top = visibleDays.min() {
            agenda.restoreDay = top
        }
        let margin = new.containerSize.height * 2
        let top = new.contentOffset.y + new.contentInsets.top
        let oldTop = old.contentOffset.y + old.contentInsets.top
        let bottom = new.contentSize.height - new.containerSize.height - new.contentOffset.y
        let oldBottom = old.contentSize.height - old.containerSize.height - old.contentOffset.y
        if (top < margin && oldTop >= margin) || (top < oldTop - 2 && top <= 0 && oldTop >= -1) {
            let first = dayGroups.first?.day
            extend {
                await agenda.extendBack()
                regroup()
                if let first { anchor(first) }
            }
        } else if (bottom < margin && oldBottom >= margin) || (bottom < oldBottom - 2 && bottom <= 0 && oldBottom >= -1) {
            extend {
                await agenda.extendHorizon()
                regroup()
            }
        } else if new.contentSize.height <= new.containerSize.height, new.contentSize.height != old.contentSize.height {
            extend {
                await agenda.extendHorizon()
                regroup()
            }
        }
    }

    private func extend(_ work: @escaping () async -> Void) {
        extending = true
        Task {
            await work()
            extending = false
        }
    }

    private func monthHeader(_ day: Date) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(day.formatted(.dateTime.month(.wide)))
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(.primary)
            Text(day.formatted(.dateTime.year()))
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.top, 46)
    }

    private func header(_ day: Date) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(Calendar.current.component(.day, from: day))")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(
                    Calendar.current.isDateInToday(day)
                        ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary)
                )
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

private struct MonthChip: View {
    @Binding var days: Set<Date>

    var body: some View {
        if let top = days.min() {
            HStack(spacing: 4) {
                Text(top.formatted(.dateTime.month(.abbreviated)))
                    .font(.system(size: 12, weight: .semibold))
                Text(top.formatted(.dateTime.year()))
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
            .animation(.default, value: top.formatted(.dateTime.month().year()))
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
