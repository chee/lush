import SwiftUI
import QuickLook
import UniformTypeIdentifiers

#if os(macOS)
import QuickLookUI

private struct QuickLookInline: NSViewRepresentable {
    let url: URL

    /// QLPreviewView reloads whenever previewItem is set, and its getter
    /// doesn't hand back what was put in, so the url it is already showing has
    /// to be remembered here — setting it every update pass restarts the load
    /// forever.
    final class Coordinator {
        var shown: URL?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.autostarts = true
        view.previewItem = url as NSURL
        context.coordinator.shown = url
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        guard context.coordinator.shown != url else { return }
        context.coordinator.shown = url
        view.previewItem = url as NSURL
    }
}
#else
private struct QuickLookInline: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let preview = QLPreviewController()
        preview.dataSource = context.coordinator
        return preview
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        guard context.coordinator.url != url else { return }
        context.coordinator.url = url
        controller.reloadData()
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(
            _ controller: QLPreviewController,
            previewItemAt index: Int
        ) -> any QLPreviewItem {
            url as NSURL
        }
    }
}
#endif

/// A `file` doc — a UnixFileEntry — opens in the system's own previewer, keyed
/// off the name, extension and mime type the doc carries. The patchwork editor
/// is a per-doc choice made from the context menu.
struct FileDetail: View {
    let docUrl: String
    var historyVersion: DocHistoryEntry? = nil
    #if os(macOS)
    var rightSidebarVisible: Binding<Bool>? = nil
    #endif
    @Environment(NotesModel.self) private var model
    @State private var file: URL?
    @State private var info: AssetInfo?
    @State private var byteCount: Int?
    @State private var loading = true

    private var name: String {
        if let name = info?.name, !name.isEmpty { return name }
        return model.node(for: docUrl)?.displayName ?? "File"
    }

    private var type: UTType? {
        if let mime = info?.mimeType, let type = UTType(mimeType: mime) { return type }
        guard let ext = info?.extension, !ext.isEmpty else { return nil }
        return UTType(filenameExtension: ext)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let description = type?.localizedDescription {
            parts.append(description)
        } else if let mime = info?.mimeType, !mime.isEmpty {
            parts.append(mime)
        }
        if let byteCount {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file))
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        preview
            .navigationTitle(name)
            .toolbar { previewToolbar }
            .task(id: docUrl + (historyVersion?.hash ?? "")) { await load() }
    }

    @ViewBuilder
    private var preview: some View {
        if let file {
            QuickLookInline(url: file)
                .background(.background)
        } else if loading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label(name, systemImage: "doc")
            } description: {
                Text(subtitle.isEmpty ? "Nothing to preview." : subtitle)
            }
        }
    }

    @ToolbarContentBuilder
    private var previewToolbar: some ToolbarContent {
        if let file {
            ToolbarItem {
                ShareLink(item: file)
            }
        }
        #if os(macOS)
        ToolbarItem {
            PatchworkEditorButton(url: docUrl)
        }
        ToolbarItem {
            Button {
                rightSidebarVisible?.wrappedValue.toggle()
            } label: {
                Label("Inspector", systemImage: "info.circle")
                    .foregroundStyle(rightSidebarVisible?.wrappedValue == true ? Color.accentColor : Color.primary)
            }
        }
        #endif
    }

    private func load() async {
        loading = true
        file = nil
        byteCount = nil
        let resolved = model.resolvedNoteUrl(docUrl)
        let url = historyVersion.flatMap { model.pinnedUrl(resolved, heads: $0.heads) } ?? resolved
        info = await model.assetInfo(url)
        guard let data = await model.assetBytes(url) else {
            loading = false
            return
        }
        byteCount = data.count
        let info = self.info
        let fallback = model.node(for: docUrl)?.displayName ?? "file"
        file = await Task.detached {
            let name = EditorCore.previewFilename(info: info, fallback: fallback, data: data)
            return AssetCache.mediaFile(for: url, name: name, data: data)
        }.value
        loading = false
    }
}
