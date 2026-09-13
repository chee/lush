import SwiftUI
import EventKit
import Intents

/// Named sets of Lush settings, built here and linked to a system Focus from
/// Settings › Focus › Focus Filters › Lush. The system decides when a Focus is
/// on; this decides what "Work" or "Weekend" means inside Lush.
struct FocusSettingsPane: View {
    @Environment(NotesModel.self) private var model
    @State private var editing: FocusPreset?

    private var focus: FocusModes { model.focus }

    var body: some View {
        Form {
            Section {
                ForEach(focus.presets) { preset in
                    Button {
                        editing = preset
                    } label: {
                        HStack {
                            Text(preset.name).foregroundStyle(Color.primary)
                            Spacer()
                            Text(summary(preset)).foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button("Delete", role: .destructive) {
                            focus.deletePresets([preset.id])
                        }
                    }
                    .contextMenu {
                        Button("Delete", role: .destructive) {
                            focus.deletePresets([preset.id])
                        }
                    }
                }
                Button("Add Focus Set") { editing = FocusPreset() }
            } header: {
                Text("Focus Sets")
            } footer: {
                Text("Build a Focus Set here, then link it from \(Self.focusSettingsPath) › Focus Filters › Lush. Anything left unset keeps its normal setting, and hidden notebooks stay searchable.")
            }

            Section {
                if let state = focus.state {
                    LabeledContent("Notebooks", value: state.shownFolderUrls.isEmpty
                        ? "All"
                        : "\(state.shownFolderUrls.count)")
                    LabeledContent("Calendars", value: state.shownCalendarIds.isEmpty
                        ? "All"
                        : "\(state.shownCalendarIds.count)")
                    LabeledContent("Inbox", value: name(state.inboxUrl) ?? "Default")
                    LabeledContent("Quick Note", value: name(state.quickNoteUrl) ?? "Default")
                } else {
                    Text("No Focus is filtering Lush.")
                        .foregroundStyle(.secondary)
                }
                Button("Open Focus Settings") { openFocusSettings() }
            } header: {
                Text("Now")
            }

            Section {
                switch focus.focusStatusAuthorization {
                case .authorized:
                    Label("Lush follows Focus changes as they happen.", systemImage: "checkmark.circle")
                case .denied, .restricted:
                    Text("Focus access is off, so a Focus that starts or ends while Lush is in the background is picked up next time Lush comes to the front.")
                        .foregroundStyle(.secondary)
                default:
                    Button("Allow Focus Access") {
                        Task { await focus.requestFocusStatusAuthorization() }
                    }
                }
            } header: {
                Text("Focus Access")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Focus")
        .sheet(item: $editing) { preset in
            FocusPresetEditor(preset: preset) { focus.save($0) }
                .environment(model)
        }
    }

    private func summary(_ preset: FocusPreset) -> String {
        var parts: [String] = []
        let folders = preset.filter.shownFolderUrls.count
        let calendars = preset.filter.shownCalendarIds.count
        if folders > 0 { parts.append("\(folders) notebook\(folders == 1 ? "" : "s")") }
        if calendars > 0 { parts.append("\(calendars) calendar\(calendars == 1 ? "" : "s")") }
        return parts.isEmpty ? "Everything" : parts.joined(separator: ", ")
    }

    private func name(_ url: String?) -> String? {
        guard let url else { return nil }
        return model.node(for: url)?.displayName ?? "Untitled"
    }

    private static var focusSettingsPath: String {
        #if os(macOS)
        "System Settings › Focus › a Focus"
        #else
        "Settings › Focus › a Focus"
        #endif
    }

    private func openFocusSettings() {
        #if os(macOS)
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Focus-Settings.extension")
        else { return }
        NSWorkspace.shared.open(url)
        #else
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
        #endif
    }
}

private struct FocusPresetEditor: View {
    @State var preset: FocusPreset
    let save: (FocusPreset) -> Void

    @Environment(NotesModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var calendars: [EKCalendar] = []

    private var folders: [(url: String, path: String)] { model.folderChoices() }
    private var notes: [(url: String, path: String)] { model.noteChoices() }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $preset.name)
                }

                Section {
                    ForEach(folders, id: \.url) { folder in
                        toggle(folder.path, on: binding(for: folder.url))
                    }
                } header: {
                    Text("Notebooks")
                } footer: {
                    Text(preset.filter.shownFolderUrls.isEmpty
                        ? "Nothing picked, so every notebook stays visible."
                        : "Only these are visible while this Focus is on.")
                }

                Section {
                    if calendars.isEmpty {
                        Text("No calendars available.").foregroundStyle(.secondary)
                    }
                    ForEach(calendars, id: \.calendarIdentifier) { calendar in
                        toggle(calendar.title, on: calendarBinding(calendar.calendarIdentifier)) {
                            Circle()
                                .fill(Agenda.color(calendar))
                                .frame(width: 10, height: 10)
                        }
                    }
                } header: {
                    Text("Calendars")
                } footer: {
                    Text(preset.filter.shownCalendarIds.isEmpty
                        ? "Nothing picked, so every calendar shows."
                        : "Only these show in the Calendar view.")
                }

                Section {
                    Picker("Inbox", selection: $preset.filter.inboxUrl) {
                        Text("Default").tag(String?.none)
                        ForEach(folders, id: \.url) { folder in
                            Text(folder.path).tag(String?.some(folder.url))
                        }
                    }
                    Picker("Quick Note", selection: $preset.filter.quickNoteUrl) {
                        Text("Default").tag(String?.none)
                        ForEach(notes, id: \.url) { note in
                            Text(note.path).tag(String?.some(note.url))
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(preset.name.isEmpty ? "Focus Set" : preset.name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save(preset)
                        dismiss()
                    }
                    .disabled(preset.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .task { calendars = await Self.allCalendars() }
    }

    private func toggle(
        _ title: String,
        on isOn: Binding<Bool>,
        @ViewBuilder icon: () -> some View = { EmptyView() }
    ) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 8) {
                icon()
                Text(title)
            }
        }
    }

    private func binding(for url: String) -> Binding<Bool> {
        Binding(
            get: { preset.filter.shownFolderUrls.contains(url) },
            set: { on in
                if on {
                    preset.filter.shownFolderUrls.append(url)
                } else {
                    preset.filter.shownFolderUrls.removeAll { $0 == url }
                }
            }
        )
    }

    private func calendarBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { preset.filter.shownCalendarIds.contains(id) },
            set: { on in
                if on {
                    preset.filter.shownCalendarIds.append(id)
                } else {
                    preset.filter.shownCalendarIds.removeAll { $0 == id }
                }
            }
        )
    }

    private static func allCalendars() async -> [EKCalendar] {
        await Task.detached {
            let store = EKEventStore()
            var seen = Set<String>()
            return (store.calendars(for: .event) + store.calendars(for: .reminder)).filter {
                seen.insert($0.calendarIdentifier).inserted
            }
        }.value
    }
}
