import SwiftUI

#if os(macOS)
import AppKit

struct LushMenuBarIcon: View {
    @Environment(NotesModel.self) private var model

    var body: some View {
        Group {
            if model.exportsInFlight > 0 {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: 15, weight: .semibold))
                    .symbolEffect(.rotate, options: .repeat(.continuous))
            } else {
                Image(systemName: "note.text")
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: 15, weight: .semibold))
            }
        }
        .frame(width: 18, height: 18)
    }
}

struct MenuBarCaptureView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var colorScheme
    @Environment(NotesModel.self) private var model
    @FocusState private var textFieldFocused: Bool
    @State private var text = ""
    @State private var status: String?
    @State private var recorder = AudioRecorder()
    @State private var isTranscribing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            TextField("", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(2...4)
                .padding(10)
                .background(fieldBackground, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(fieldBorder, lineWidth: 1)
                }
                .focused($textFieldFocused)
                .onSubmit { submitText() }

            HStack(spacing: 8) {
                Button {
                    submitText()
                } label: {
                    Label("Capture", systemImage: "return")
                }
                .keyboardShortcut(.return, modifiers: [])
                .buttonStyle(.borderedProminent)
                .disabled(trimmedText.isEmpty)

                Button {
                    appendClipboard()
                } label: {
                    Label("Clipboard", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)
            }

            Divider()
                .overlay(dividerColor)

            actionGrid

            if recorder.isRecording || recorder.permissionDenied || isTranscribing {
                recordingSection
            }

            if let status {
                Text(status)
                    .uiFont(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 320)
        .background {
            panelBackground
        }
        .task {
            await model.start()
            textFieldFocused = true
        }
        .onExitCommand {
            closeMenuWindow()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
                .frame(width: 18, height: 18)
            Text("Lush")
                .uiFont(.headline)
            Spacer()
            Button {
                closeMenuWindow()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Close")
        }
    }

    private var actionGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                menuAction("New Note", systemImage: "square.and.pencil") {
                    AppRouter.shared.pending = .newNote
                    openLush()
                }
                menuAction("Record", systemImage: recorder.isRecording ? "stop.circle" : "waveform.circle") {
                    toggleRecording()
                }
            }
            GridRow {
                menuAction("Search", systemImage: "magnifyingglass") {
                    AppRouter.shared.pending = .search("")
                    openLush()
                }
                menuAction("Quick Note", systemImage: "bolt.circle") {
                    AppRouter.shared.pending = .quickNote
                    openLush()
                }
            }
            GridRow {
                menuAction("Open Lush", systemImage: "arrow.up.forward.app") {
                    openLush()
                }
                menuAction("Quit", systemImage: "power") {
                    LushAppDelegate.reallyQuit()
                }
            }
        }
    }

    private var recordingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if recorder.isRecording {
                HStack(spacing: 8) {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                        .scaleEffect(1 + CGFloat(recorder.level) * 0.45)
                        .animation(.easeOut(duration: 0.1), value: recorder.level)
                    Text(timeString(recorder.elapsed))
                        .font(.caption.monospacedDigit())
                    Capsule()
                        .fill(.red.opacity(0.35 + Double(recorder.level) * 0.65))
                        .frame(width: 72 + CGFloat(recorder.level) * 70, height: 4)
                    Spacer()
                }
            }

            HStack(spacing: 8) {
                if recorder.isRecording {
                    Button("Cancel", role: .cancel) {
                        recorder.cancel()
                        status = "Recording cancelled"
                    }
                    Button("Done") {
                        finishRecording()
                    }
                    .buttonStyle(.borderedProminent)
                } else if isTranscribing {
                    ProgressView()
                        .controlSize(.small)
                    Text("Transcribing")
                        .uiFont(.caption)
                        .foregroundStyle(.secondary)
                } else if recorder.permissionDenied {
                    Text("Microphone access denied")
                        .uiFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(sectionBackground, in: RoundedRectangle(cornerRadius: 8))
    }

    private var isDarkMode: Bool { colorScheme == .dark }

    private var panelBackground: LinearGradient {
        LinearGradient(
            colors: isDarkMode ? [
                Color(red: 0.10, green: 0.11, blue: 0.13),
                Color(red: 0.13, green: 0.12, blue: 0.16),
                Color(red: 0.12, green: 0.10, blue: 0.09)
            ] : [
                Color(red: 1.0, green: 0.93, blue: 0.88),
                Color(red: 1.0, green: 0.82, blue: 0.79),
                Color(red: 0.98, green: 0.93, blue: 0.78)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var fieldBackground: Color {
        isDarkMode ? Color.white.opacity(0.08) : Color.white.opacity(0.72)
    }

    private var sectionBackground: Color {
        isDarkMode ? Color.white.opacity(0.06) : Color.white.opacity(0.55)
    }

    private var fieldBorder: Color {
        isDarkMode ? Color.white.opacity(0.16) : Color.white.opacity(0.9)
    }

    private var dividerColor: Color {
        isDarkMode ? Color.white.opacity(0.18) : Color.white.opacity(0.7)
    }

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func menuAction(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .frame(width: 142)
    }

    private func submitText() {
        let snippet = trimmedText
        guard !snippet.isEmpty else { return }
        text = ""
        status = "Saving..."
        Task {
            let url = await model.appendToQuickNote(snippet)
            status = url == nil ? "Couldn't update Quick Note" : "Captured to Quick Note"
        }
    }

    private func appendClipboard() {
        let clipboard = NSPasteboard.general.string(forType: .string) ?? ""
        let snippet = clipboard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !snippet.isEmpty else {
            status = "Clipboard is empty"
            return
        }
        status = "Saving clipboard..."
        Task {
            let url = await model.appendToQuickNote(snippet)
            status = url == nil ? "Couldn't update Quick Note" : "Clipboard added to Quick Note"
        }
    }

    private func toggleRecording() {
        if recorder.isRecording {
            finishRecording()
            return
        }
        status = nil
        recorder.permissionDenied = false
        Task { await recorder.start() }
    }

    private func finishRecording() {
        guard let data = recorder.stop() else {
            status = "Recording was empty"
            return
        }
        isTranscribing = true
        status = nil
        Task {
            let transcript = await Transcriber.transcribe(data, fileExtension: "m4a")
            isTranscribing = false
            let url = await model.appendRecordingToQuickNote(data: data, transcript: transcript)
            if url == nil {
                status = "Couldn't update Quick Note"
            } else if transcript == nil {
                status = "Recording added; transcript unavailable"
            } else {
                status = "Recording and transcript added"
            }
        }
    }

    private func openLush() {
        dismiss()
        NSApp.setActivationPolicy(.regular)
        openWindow(id: "main")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            NSApp.unhide(nil)
            NSRunningApplication.current.activate(options: [.activateAllWindows])
            NSApp.windows
                .filter { $0.level == .normal && $0.canBecomeMain }
                .forEach { window in
                    if window.isMiniaturized {
                        window.deminiaturize(nil)
                    }
                    window.makeKeyAndOrderFront(nil)
                }
        }
    }

    private func closeMenuWindow() {
        dismiss()
    }

    private func timeString(_ t: TimeInterval) -> String {
        let seconds = Int(t)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
#endif
