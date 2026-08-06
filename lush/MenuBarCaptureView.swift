import SwiftUI

#if os(macOS)
import AppKit

struct MenuBarCaptureView: View {
    @Environment(NotesModel.self) private var model
    @FocusState private var textFieldFocused: Bool
    @State private var text = ""
    @State private var status: String?
    @State private var recorder = AudioRecorder()
    @State private var isTranscribing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            TextField("Catch a thought", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(2...4)
                .padding(10)
                .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.9), lineWidth: 1)
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
                .overlay(Color.white.opacity(0.7))

            actionGrid

            if recorder.isRecording || recorder.permissionDenied || isTranscribing {
                recordingSection
            }

            if let status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 320)
        .background {
            LinearGradient(
                colors: [
                    Color(red: 1.0, green: 0.93, blue: 0.88),
                    Color(red: 1.0, green: 0.82, blue: 0.79),
                    Color(red: 0.98, green: 0.93, blue: 0.78)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
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
            Image(systemName: "text.badge.plus")
                .font(.title3)
                .foregroundStyle(Color(red: 0.72, green: 0.22, blue: 0.34))
            Text("Lush")
                .font(.headline)
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
                menuAction("Open Lush", systemImage: "arrow.up.forward.app") {
                    openLush()
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
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if recorder.permissionDenied {
                    Text("Microphone access denied")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
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
            guard let transcript else {
                status = "Recording saved, but transcription is unavailable"
                return
            }
            let url = await model.appendToQuickNote(transcript)
            status = url == nil ? "Couldn't update Quick Note" : "Recording transcript added"
        }
    }

    private func openLush() {
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closeMenuWindow() {
        NSApp.keyWindow?.performClose(nil)
    }

    private func timeString(_ t: TimeInterval) -> String {
        let seconds = Int(t)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
#endif
