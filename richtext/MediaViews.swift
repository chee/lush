import SwiftUI
import AVFoundation
import AVKit
import WebKit

struct EditorSheetView: View {
    let sheet: EditorSheet
    let controller: EditorController

    var body: some View {
        switch sheet {
        case .audio(let assetUrl, let fileURL, let name):
            AudioPlayerSheet(fileURL: fileURL, name: name) { data in
                let base = (name as NSString).deletingPathExtension
                controller.replaceTrimmedAudio(
                    assetUrl: assetUrl,
                    data: data,
                    name: "\(base) (trimmed).m4a"
                )
            }
        case .video(let fileURL, let name):
            VideoPlayerSheet(fileURL: fileURL, name: name)
        case .html(let handle):
            HtmlEditorSheet(html: handle.html) { controller.saveHtml(handle, html: $0) }
        case .table(let handle):
            TableEditorSheet(grid: handle.box.grid) { controller.saveTable(handle, grid: $0) }
        }
    }
}

struct AudioPlayerSheet: View {
    let fileURL: URL
    let name: String
    let onTrimmed: (Data) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVAudioPlayer?
    @State private var playing = false
    @State private var position: TimeInterval = 0
    @State private var duration: TimeInterval = 0.01
    @State private var trimming = false
    @State private var trimStart: TimeInterval = 0
    @State private var trimEnd: TimeInterval = 0.01
    @State private var exporting = false
    @State private var exportFailed = false

    var body: some View {
        VStack(spacing: 16) {
            Text(name)
                .font(.headline)
                .lineLimit(1)
            HStack {
                Text(timeString(position))
                Slider(value: $position, in: 0...duration) { editing in
                    if !editing {
                        player?.currentTime = position
                    }
                }
                Text(timeString(duration))
            }
            .font(.caption.monospacedDigit())
            Button {
                togglePlayback()
            } label: {
                Image(systemName: playing ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 44))
            }
            .buttonStyle(.plain)

            if trimming {
                VStack(spacing: 8) {
                    HStack {
                        Text("Start \(timeString(trimStart))")
                        Slider(value: $trimStart, in: 0...trimEnd)
                    }
                    HStack {
                        Text("End \(timeString(trimEnd))")
                        Slider(value: $trimEnd, in: trimStart...duration)
                    }
                    if exportFailed {
                        Text("Couldn't trim this recording.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    HStack {
                        Button("Cancel") { trimming = false }
                        Button("Save Trimmed Copy") {
                            Task { await exportTrim() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(exporting || trimEnd - trimStart < 0.2)
                    }
                }
                .font(.caption.monospacedDigit())
            } else {
                Button("Trim…") {
                    trimStart = 0
                    trimEnd = duration
                    trimming = true
                }
            }

            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(24)
        #if os(macOS)
        .frame(minWidth: 420)
        #endif
        .task {
            let loaded = try? AVAudioPlayer(contentsOf: fileURL)
            loaded?.prepareToPlay()
            player = loaded
            duration = max(loaded?.duration ?? 0.01, 0.01)
            trimEnd = duration
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let player else { continue }
                if playing {
                    position = player.currentTime
                    if !player.isPlaying {
                        playing = false
                    }
                }
            }
        }
        .onDisappear {
            player?.stop()
        }
    }

    private func togglePlayback() {
        guard let player else { return }
        if playing {
            player.pause()
            playing = false
        } else {
            if position >= duration - 0.05 {
                player.currentTime = 0
            }
            player.play()
            playing = true
        }
    }

    private func exportTrim() async {
        guard let session = AVAssetExportSession(
            asset: AVURLAsset(url: fileURL),
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            exportFailed = true
            return
        }
        exporting = true
        exportFailed = false
        session.timeRange = CMTimeRange(
            start: CMTime(seconds: trimStart, preferredTimescale: 600),
            end: CMTime(seconds: trimEnd, preferredTimescale: 600)
        )
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("trim-\(UUID().uuidString).m4a")
        do {
            try await session.export(to: out, as: .m4a)
            let data = try Data(contentsOf: out)
            try? FileManager.default.removeItem(at: out)
            onTrimmed(data)
            dismiss()
        } catch {
            exportFailed = true
        }
        exporting = false
    }

    private func timeString(_ t: TimeInterval) -> String {
        let seconds = Int(t)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

struct VideoPlayerSheet: View {
    let fileURL: URL
    let name: String
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        VStack(spacing: 12) {
            Text(name)
                .font(.headline)
                .lineLimit(1)
            VideoPlayer(player: player)
                .frame(minHeight: 280)
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 420)
        #endif
        .onAppear {
            let p = AVPlayer(url: fileURL)
            player = p
            p.play()
        }
        .onDisappear {
            player?.pause()
        }
    }
}

struct HtmlEditorSheet: View {
    @State var html: String
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .split
    @State private var page = WebPage()

    enum Mode: String, CaseIterable, Identifiable {
        case preview = "Preview"
        case code = "HTML"
        case split = "Split"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 280)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    onSave(html)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            Group {
                switch mode {
                case .preview:
                    preview
                case .code:
                    codeEditor
                case .split:
                    #if os(macOS)
                    HStack(spacing: 12) {
                        codeEditor
                        preview
                    }
                    #else
                    VStack(spacing: 12) {
                        codeEditor
                        preview
                    }
                    #endif
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(16)
        #if os(macOS)
        .frame(minWidth: 680, minHeight: 460)
        #endif
        .onChange(of: html, initial: true) {
            page.load(html: wrapped(html), baseURL: URL(string: "about:blank")!)
        }
    }

    private var preview: some View {
        WebView(page)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.separator)
            )
    }

    private var codeEditor: some View {
        TextEditor(text: $html)
            .font(.system(size: 13, design: .monospaced))
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.separator)
            )
    }

    private func wrapped(_ body: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        :root { color-scheme: light dark; }
        body { font: -apple-system-body; font-family: -apple-system, sans-serif; margin: 12px; }
        </style></head><body>\(body)</body></html>
        """
    }
}

struct TableEditorSheet: View {
    @State var grid: TableGrid
    let onSave: (TableGrid) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Toggle("Header row", isOn: $grid.hasHeader)
                    .fixedSize()
                Spacer()
                Button("Add Row", systemImage: "plus") { addRow() }
                Button("Remove Row", systemImage: "minus") { removeRow() }
                    .disabled(grid.rows.count <= 1)
                Button("Add Column", systemImage: "plus") { addColumn() }
                Button("Remove Column", systemImage: "minus") { removeColumn() }
                    .disabled(grid.columnCount <= 1)
            }
            .labelStyle(.titleOnly)
            ScrollView([.vertical, .horizontal]) {
                Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                    ForEach(0..<grid.rows.count, id: \.self) { r in
                        GridRow {
                            ForEach(0..<grid.columnCount, id: \.self) { c in
                                TextField("", text: cellBinding(r, c))
                                    .textFieldStyle(.roundedBorder)
                                    .font(grid.hasHeader && r == 0 ? .body.bold() : .body)
                                    .frame(width: 150)
                            }
                        }
                    }
                }
                .padding(2)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    onSave(grid)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 360)
        #endif
    }

    private func cellBinding(_ r: Int, _ c: Int) -> Binding<String> {
        Binding(
            get: {
                guard r < grid.rows.count, c < grid.rows[r].count else { return "" }
                return grid.rows[r][c]
            },
            set: { value in
                guard r < grid.rows.count, c < grid.rows[r].count else { return }
                grid.rows[r][c] = value
            }
        )
    }

    private func addRow() {
        grid.rows.append(Array(repeating: "", count: max(grid.columnCount, 1)))
    }

    private func removeRow() {
        guard grid.rows.count > 1 else { return }
        grid.rows.removeLast()
    }

    private func addColumn() {
        grid.rows = grid.rows.map { $0 + [""] }
    }

    private func removeColumn() {
        guard grid.columnCount > 1 else { return }
        grid.rows = grid.rows.map { Array($0.dropLast()) }
    }
}
