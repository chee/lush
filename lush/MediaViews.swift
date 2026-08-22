import SwiftUI
import AVFoundation
import CoreLocation
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
    @State private var player: AVPlayer?

    var body: some View {
        PlatformVideoPlayer(player: player)
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

#if os(macOS)
struct PlatformVideoPlayer: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}
#else
struct PlatformVideoPlayer: View {
    let player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
    }
}
#endif

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
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.separator)
            )
    }
}

/// Inline voice-memo box: play button, waveform with progress, name and
/// transcript. The scissors button opens the full player sheet for trimming.
struct AudioInlineView: View {
    let name: String
    let fileURL: URL
    let transcript: String?
    let onOpen: () -> Void
    @State private var player: AVAudioPlayer?
    @State private var playing = false
    @State private var progress: Double = 0
    @State private var levels: [Float] = []
    @ScaledMetric(relativeTo: .largeTitle) private var playButtonSize: CGFloat = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button {
                    togglePlayback()
                } label: {
                    Image(systemName: playing ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: playButtonSize))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 3) {
                    Text(name)
                        .uiFont(.caption, weight: .medium)
                        .lineLimit(1)
                    WaveformView(levels: levels, progress: progress) { frac in
                            seekTo(frac)
                        }
                        .frame(height: 26)
                }
                Button {
                    player?.pause()
                    playing = false
                    onOpen()
                } label: {
                    Image(systemName: "scissors")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            if let transcript {
                Text(transcript)
                    .uiFont(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.secondary.opacity(0.2))
        )
        .task {
            let url = fileURL
            levels = await Task.detached { WaveformView.levels(for: url) }.value
        }
        .task(id: playing) {
            while playing, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let player else { continue }
                progress = player.duration > 0 ? player.currentTime / player.duration : 0
                if !player.isPlaying {
                    playing = false
                    progress = 0
                }
            }
        }
        .onDisappear {
            player?.stop()
        }
    }

    private func togglePlayback() {
        if player == nil {
            player = try? AVAudioPlayer(contentsOf: fileURL)
            player?.prepareToPlay()
        }
        guard let player else { return }
        if playing {
            player.pause()
            playing = false
        } else {
            player.play()
            playing = true
        }
    }

    private func seekTo(_ fraction: Double) {
        if player == nil {
            player = try? AVAudioPlayer(contentsOf: fileURL)
            player?.prepareToPlay()
        }
        guard let player else { return }
        player.currentTime = fraction * player.duration
        progress = fraction
        if !playing {
            player.play()
            playing = true
        }
    }
}

struct WaveformView: View {
    let levels: [Float]
    let progress: Double
    var onSeek: ((Double) -> Void)? = nil

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                let bars = levels.isEmpty ? [Float](repeating: 0.3, count: 40) : levels
                let barWidth = size.width / CGFloat(bars.count)
                let playedX = size.width * CGFloat(progress)
                for (index, level) in bars.enumerated() {
                    let height = max(2, CGFloat(level) * size.height)
                    let x = CGFloat(index) * barWidth
                    let rect = CGRect(
                        x: x + barWidth * 0.15,
                        y: (size.height - height) / 2,
                        width: barWidth * 0.7,
                        height: height
                    )
                    let played = x < playedX
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: barWidth * 0.35),
                        with: .color(played ? Color.accentColor : Color.secondary.opacity(0.45))
                    )
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard let onSeek else { return }
                        let frac = max(0, min(1, Double(value.location.x / geo.size.width)))
                        onSeek(frac)
                    }
            )
        }
    }

    nonisolated static func levels(for fileURL: URL, bars: Int = 48) -> [Float] {
        guard let file = try? AVAudioFile(forReading: fileURL) else { return [] }
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: frameCount
              ),
              (try? file.read(into: buffer)) != nil,
              let samples = buffer.floatChannelData?[0]
        else { return [] }
        let total = Int(buffer.frameLength)
        guard total > 0 else { return [] }
        let binSize = max(total / bars, 1)
        var peaks: [Float] = []
        var maxPeak: Float = 0.001
        for bin in 0..<bars {
            let start = bin * binSize
            guard start < total else { break }
            var peak: Float = 0
            for i in start..<min(start + binSize, total) {
                peak = max(peak, abs(samples[i]))
            }
            peaks.append(peak)
            maxPeak = max(maxPeak, peak)
        }
        return peaks.map { $0 / maxPeak }
    }
}

struct TrimWaveformView: View {
    let levels: [Float]
    let duration: TimeInterval
    @Binding var trimStart: TimeInterval
    @Binding var trimEnd: TimeInterval
    var playhead: Double = 0

    @State private var movingEnd: Bool? = nil

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let sf = CGFloat(duration > 0 ? trimStart / duration : 0)
            let ef = CGFloat(duration > 0 ? trimEnd / duration : 1)
            let ph = CGFloat(playhead)

            Canvas { ctx, size in
                let bars = levels.isEmpty ? [Float](repeating: 0.3, count: 48) : levels
                let barWidth = size.width / CGFloat(bars.count)
                for (i, level) in bars.enumerated() {
                    let barFrac = (CGFloat(i) + 0.5) / CGFloat(bars.count)
                    let inTrim = barFrac >= sf && barFrac <= ef
                    let barH = max(2, CGFloat(level) * size.height)
                    let x = CGFloat(i) * barWidth
                    let rect = CGRect(
                        x: x + barWidth * 0.15,
                        y: (size.height - barH) / 2,
                        width: barWidth * 0.7,
                        height: barH
                    )
                    ctx.fill(
                        Path(roundedRect: rect, cornerRadius: barWidth * 0.35),
                        with: .color(inTrim ? Color.accentColor : Color.secondary.opacity(0.2))
                    )
                }
                let playX = ph * size.width
                ctx.fill(
                    Path(CGRect(x: playX - 1, y: 0, width: 2, height: size.height)),
                    with: .color(.white.opacity(0.75))
                )
                for frac in [sf, ef] {
                    let x = frac * size.width
                    ctx.fill(
                        Path(CGRect(x: max(0, x - 1.5), y: 0, width: 3, height: size.height)),
                        with: .color(Color.accentColor)
                    )
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let x = max(0, min(w, value.location.x))
                        let frac = Double(x / w)
                        if movingEnd == nil {
                            movingEnd = abs(frac - Double(ef)) < abs(frac - Double(sf))
                        }
                        if movingEnd == true {
                            trimEnd = max(trimStart + 0.2, min(duration, frac * duration))
                        } else {
                            trimStart = max(0, min(trimEnd - 0.2, frac * duration))
                        }
                    }
                    .onEnded { _ in movingEnd = nil }
            )
        }
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
                fetchML: { await controller.assetML(assetUrl) },
                generateML: { await controller.generateAssetML(assetUrl: assetUrl, name: name, choice: $0) },
                fetchVision: { await controller.assetVision(assetUrl) },
                saveTranscript: { transcript in
                    controller.saveTranscript(assetUrl: assetUrl, transcript: transcript)
                }
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
        case .logline(let handle):
            LoglineEditorSheet(draft: handle.draft, isNew: handle.box == nil) {
                controller.saveLogline(handle, draft: $0)
            }
        case .info(let assetUrl, let name, let image, let block):
            AssetInfoSheet(
                name: name,
                image: image,
                altText: block.value.altText,
                fetchML: { await controller.assetML(assetUrl) },
                generateML: { await controller.generateAssetML(assetUrl: assetUrl, name: name, choice: $0) },
                fetch: { await controller.assetVision(assetUrl) },
                analyze: { await controller.analyzeAssetVision(assetUrl) },
                saveAltText: { controller.saveImageAltText(block, altText: $0) }
            )
        case .patchworkCreate:
            PatchworkCreateSheet(controller: controller)
        case .link(let initial):
            LinkSheet(url: initial) { controller.applyLink($0) }
        }
    }
}

struct AssetInfoSheet: View {
    let name: String
    let image: PImage?
    @State var altText: String
    let fetchML: () async -> AssetMl?
    let generateML: (ModelChoice?) async -> AssetMl?
    let fetch: () async -> AssetVision?
    let analyze: () async -> AssetVision?
    let saveAltText: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var ml: AssetMl?
    @State private var vision: AssetVision?
    @State private var loaded = false
    @State private var analyzing = false
    @State private var generatingML = false
    @State private var modelChoice: ModelChoice?

    var body: some View {
        VStack(spacing: 12) {
            Text(name)
                .uiFont(.headline)
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
            VStack(alignment: .leading, spacing: 4) {
                Text("Alt Text")
                    .uiFont(.caption)
                    .foregroundStyle(.secondary)
                TextField("Describe this image", text: $altText, axis: .vertical)
                    .lineLimit(2...4)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let vision {
                        if !vision.ocr.isEmpty {
                            CopyableText(title: "Recognized Text", text: vision.ocr)
                        }
                        if !vision.description.isEmpty {
                            CopyableText(title: "Description", text: vision.description)
                        }
                    }
                    if let ml {
                        if !ml.summary.isEmpty {
                            CopyableText(title: "Summary", text: ml.summary)
                        }
                        if !ml.caption.isEmpty {
                            CopyableText(title: "Caption", text: ml.caption)
                        }
                        if !ml.keywords.isEmpty {
                            CopyableText(title: "Keywords", text: ml.keywords)
                        }
                    } else if ml == nil, analyzing {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Looking at the image…")
                                .uiFont(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if ml == nil, loaded {
                        Text("Nothing recognized in this image.")
                            .uiFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                ModelChoiceMenu(operation: .attachmentSummary, selection: $modelChoice)
                    .uiFont(.caption)
                    .disabled(generatingML)
                Button {
                    Task { await regenerateML() }
                } label: {
                    if generatingML {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(ml == nil ? "Generate Summary" : "Regenerate Summary")
                    }
                }
                .disabled(generatingML || analyzing)
            }
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(20)
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 380)
        #endif
        .task {
            ml = await fetchML()
            vision = await fetch()
            // Assets inserted on another device, or before there was an
            // analyzer, arrive with nothing — so look now rather than show an
            // empty sheet.
            if vision == nil {
                analyzing = true
                vision = await analyze()
                analyzing = false
            }
            loaded = true
        }
        .onDisappear { saveAltText(altText) }
    }

    private func regenerateML() async {
        generatingML = true
        defer { generatingML = false }
        if vision == nil {
            analyzing = true
            vision = await analyze()
            analyzing = false
        }
        ml = await generateML(modelChoice)
        vision = await fetch()
    }
}

struct CopyableText: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .uiFont(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy") { Clipboard.copy(text) }
                    .uiFont(.caption)
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
    let fetchML: () async -> AssetMl?
    let generateML: (ModelChoice?) async -> AssetMl?
    let fetchVision: () async -> AssetVision?
    let saveTranscript: ((String) -> Void)?
    let onTrimmed: (Data) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVAudioPlayer?
    @State private var playing = false
    @State private var position: TimeInterval = 0
    @State private var duration: TimeInterval = 0.01
    @State private var trimming = false
    @ScaledMetric(relativeTo: .largeTitle) private var playButtonSize: CGFloat = 44
    @State private var trimStart: TimeInterval = 0
    @State private var trimEnd: TimeInterval = 0.01
    @State private var exporting = false
    @State private var exportFailed = false
    @State private var levels: [Float] = []
    @State private var ml: AssetMl?
    @State private var generatingML = false
    @State private var modelChoice: ModelChoice?
    @State private var editableTranscript = ""

    var body: some View {
        VStack(spacing: 16) {
            Text(name)
                .uiFont(.headline)
                .lineLimit(1)

            if trimming {
                TrimWaveformView(
                    levels: levels,
                    duration: duration,
                    trimStart: $trimStart,
                    trimEnd: $trimEnd,
                    playhead: duration > 0 ? position / duration : 0
                )
                .frame(height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                HStack {
                    Text(timeString(trimStart))
                    Spacer()
                    Text(timeString(trimEnd))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            } else {
                WaveformView(levels: levels, progress: duration > 0 ? position / duration : 0) { frac in
                    position = frac * duration
                    player?.currentTime = position
                }
                .frame(height: 44)
                HStack {
                    Text(timeString(position))
                    Spacer()
                    Text(timeString(duration))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            Button {
                togglePlayback()
            } label: {
                Image(systemName: playing ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: playButtonSize))
            }
            .buttonStyle(.plain)

            if trimming {
                if exportFailed {
                    Text("Couldn't trim this recording.")
                        .uiFont(.caption)
                        .foregroundStyle(.red)
                }
                HStack(spacing: 12) {
                    Button("Cancel") { trimming = false }
                    Button("Save Trimmed Copy") {
                        Task { await exportTrim() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(exporting || trimEnd - trimStart < 0.2)
                }
            } else {
                Button("Trim…") {
                    trimStart = 0
                    trimEnd = duration
                    trimming = true
                }
            }

            if let ml {
                VStack(alignment: .leading, spacing: 8) {
                    if !ml.summary.isEmpty {
                        CopyableText(title: "Summary", text: ml.summary)
                    }
                    if !ml.keywords.isEmpty {
                        CopyableText(title: "Keywords", text: ml.keywords)
                    }
                }
            }

            HStack {
                ModelChoiceMenu(operation: .voiceNoteSummary, selection: $modelChoice)
                    .uiFont(.caption)
                    .disabled(generatingML)
                Button {
                    Task { await regenerateML() }
                } label: {
                    if generatingML {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(ml == nil ? "Generate Summary" : "Regenerate Summary")
                    }
                }
                .disabled(generatingML || editableTranscript.isEmpty)
            }

            if !editableTranscript.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Transcript")
                            .uiFont(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Copy") { Clipboard.copy(editableTranscript) }
                            .uiFont(.caption)
                    }
                    TextEditor(text: $editableTranscript)
                        .uiFont(.caption)
                        .frame(minHeight: 80, maxHeight: 160)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(Color.secondary.opacity(0.07))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }

            Button("Done") {
                if !editableTranscript.isEmpty {
                    saveTranscript?(editableTranscript)
                }
                dismiss()
            }
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
            let url = fileURL
            Task {
                levels = await Task.detached { WaveformView.levels(for: url) }.value
            }
            Task {
                ml = await fetchML()
                if let ocr = await fetchVision()?.ocr, !ocr.isEmpty {
                    editableTranscript = ocr
                }
            }
        }
        .task(id: playing) {
            while playing, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let player else { continue }
                position = player.currentTime
                if !player.isPlaying {
                    playing = false
                }
            }
        }
        .onDisappear {
            player?.stop()
        }
    }

    private func regenerateML() async {
        guard !editableTranscript.isEmpty else { return }
        generatingML = true
        defer { generatingML = false }
        saveTranscript?(editableTranscript)
        ml = await generateML(modelChoice)
    }

    private func togglePlayback() {
        guard let player else { return }
        if playing {
            player.pause()
            playing = false
        } else {
            if trimming {
                if position < trimStart || position >= trimEnd - 0.05 {
                    player.currentTime = trimStart
                    position = trimStart
                }
            } else if position >= duration - 0.05 {
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
                .uiFont(.headline)
                .lineLimit(1)
            PlatformVideoPlayer(player: player)
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
        .task(id: html) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
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
            .font(.system(.body, design: .monospaced))
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

struct LoglineEditorSheet: View {
    @State var draft: LoglineDraft
    let isNew: Bool
    let onSave: (LoglineDraft) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var pickingPoint = false

    private static let zones = TimeZone.knownTimeZoneIdentifiers.sorted()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? "New Logline" : "Edit Logline").font(.headline)
            Form {
                Section("When") {
                    DatePicker(
                        "Date and time",
                        selection: $draft.date,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    // so the picker shows and edits the clock face of the zone
                    // the logline is being given, not the reader's
                    .environment(\.timeZone, draft.zone)
                    Picker("Time zone", selection: zone) {
                        ForEach(Self.zones, id: \.self) { Text($0).tag($0) }
                    }
                }
                Section("Where") {
                    TextField("Place", text: $draft.location)
                    TextField("Latitude", text: $draft.latitude)
                        .autocorrectionDisabled()
                    TextField("Longitude", text: $draft.longitude)
                        .autocorrectionDisabled()
                    Button("Find on a Map…") { pickingPoint = true }
                    if draft.coordinateIsBroken {
                        Label(
                            "Needs both, as numbers, within ±90 and ±180. Saving now drops them.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                Section("Weather") {
                    TextField("Weather", text: $draft.weather)
                }
                Section {
                    ForEach($draft.extras) { $extra in
                        HStack(spacing: 8) {
                            TextField("Key", text: $extra.key)
                                .autocorrectionDisabled()
                            TextField("Value", text: $extra.value)
                            Button {
                                draft.extras.removeAll { $0.id == extra.id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                    }
                    Button("Add Detail") {
                        draft.extras.append(LoglineDraft.Extra(key: "", value: ""))
                    }
                } header: {
                    Text("Details")
                } footer: {
                    Text("Anything else the logline records — what was playing, who was there. A row with no key is dropped.")
                }
                Section("Preview") {
                    Text(LoglineStampFormat.string(for: draft.date, zone: draft.zone))
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(isNew ? "Insert" : "Save") {
                    onSave(draft)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        #if os(macOS)
        .frame(width: 420, height: 560)
        #endif
        .sheet(isPresented: $pickingPoint) {
            MapPointPicker(
                start: draft.coordinate.map {
                    CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
                },
                initialName: draft.location,
                showsRadius: false,
                requiresName: false,
                confirmTitle: "Use This Place"
            ) { point in
                draft.latitude = String(point.coordinate.latitude)
                draft.longitude = String(point.coordinate.longitude)
                // the reverse-geocoded name is a suggestion, not a correction:
                // a place already named by hand keeps its name
                if draft.location.trimmingCharacters(in: .whitespaces).isEmpty {
                    draft.location = point.name
                }
            }
        }
    }

    /// Changing the zone means "it was this o'clock over there", not "it was
    /// this same instant, renamed". Keep the numbers on the clock face and
    /// move the instant under them.
    private var zone: Binding<String> {
        Binding(
            get: { draft.zone.identifier },
            set: { identifier in
                guard let next = TimeZone(identifier: identifier) else { return }
                var from = Calendar(identifier: .gregorian)
                from.timeZone = draft.zone
                var to = from
                to.timeZone = next
                let face = from.dateComponents(
                    [.year, .month, .day, .hour, .minute, .second],
                    from: draft.date
                )
                draft.date = to.date(from: face) ?? draft.date
                draft.zone = next
            }
        )
    }
}

struct LinkSheet: View {
    @State var url: String
    let onApply: (String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Link").font(.headline)
            TextField("https://", text: $url)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
                .focused($focused)
                .onSubmit(apply)
            HStack {
                Button("Remove") {
                    onApply(nil)
                    dismiss()
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Apply", action: apply)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(16)
        #if os(macOS)
        .frame(width: 380)
        #endif
        .onAppear { focused = true }
    }

    private var trimmed: String {
        url.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func apply() {
        guard !trimmed.isEmpty else { return }
        onApply(LinkSheet.normalized(trimmed))
        dismiss()
    }

    static func normalized(_ url: String) -> String {
        if url.contains("://") || url.hasPrefix("mailto:") { return url }
        if url.contains("@"), !url.contains("/") { return "mailto:" + url }
        return "https://" + url
    }
}
