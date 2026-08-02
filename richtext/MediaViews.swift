import SwiftUI
import AVFoundation
import AVKit
import WebKit

enum HtmlPreview {
    static func wrapped(_ body: String) -> String {
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

struct VideoInlineView: View {
    let fileURL: URL
    let size: CGSize
    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onAppear {
                if player == nil {
                    player = AVPlayer(url: fileURL)
                }
            }
            .onDisappear {
                player?.pause()
            }
    }
}

struct HtmlInlineView: View {
    let html: String
    let onEdit: () -> Void
    @State private var page = WebPage()

    var body: some View {
        WebView(page)
            .onAppear {
                page.load(html: HtmlPreview.wrapped(html), baseURL: URL(string: "about:blank")!)
            }
            .overlay(alignment: .topTrailing) {
                Button {
                    onEdit()
                } label: {
                    Image(systemName: "pencil.circle.fill")
                        .foregroundStyle(.secondary)
                        .background(Circle().fill(.background))
                }
                .buttonStyle(.plain)
                .padding(4)
            }
            .frame(width: 460, height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.separator)
            )
    }
}

struct EditorSheetView: View {
    let sheet: EditorSheet
    let controller: EditorController

    var body: some View {
        switch sheet {
        case .audio(let assetUrl, let fileURL, let name):
            AudioPlayerSheet(
                fileURL: fileURL,
                name: name,
                fetchVision: { await controller.assetVision(assetUrl) }
            ) { data in
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
        case .info(let assetUrl, let name, let image):
            AssetInfoSheet(name: name, image: image) {
                await controller.assetVision(assetUrl)
            }
        case .patchworkCreate:
            PatchworkCreateSheet(controller: controller)
        }
    }
}

struct AssetInfoSheet: View {
    let name: String
    let image: PImage?
    let fetch: () async -> AssetVision?
    @Environment(\.dismiss) private var dismiss
    @State private var vision: AssetVision?
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 12) {
            Text(name)
                .font(.headline)
                .lineLimit(1)
            if let image {
                #if os(macOS)
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 240)
                #else
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 240)
                #endif
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let vision {
                        if !vision.description.isEmpty {
                            CopyableText(title: "Description", text: vision.description)
                        }
                        if !vision.ocr.isEmpty {
                            CopyableText(title: "Text", text: vision.ocr)
                        }
                    } else if loaded {
                        Text("No description or recognized text yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(20)
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 380)
        #endif
        .task {
            vision = await fetch()
            loaded = true
        }
    }
}

struct CopyableText: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy") { Clipboard.copy(text) }
                    .font(.caption)
            }
            Text(text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct AudioPlayerSheet: View {
    let fileURL: URL
    let name: String
    let fetchVision: () async -> AssetVision?
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
    @State private var transcript: String?

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

            if let transcript {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Transcript")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Copy") { Clipboard.copy(transcript) }
                            .font(.caption)
                    }
                    ScrollView {
                        Text(transcript)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 140)
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
            Task {
                if let ocr = await fetchVision()?.ocr, !ocr.isEmpty {
                    transcript = ocr
                }
            }
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
            page.load(html: HtmlPreview.wrapped(html), baseURL: URL(string: "about:blank")!)
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

}

