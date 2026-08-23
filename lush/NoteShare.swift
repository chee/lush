import SwiftUI
import UniformTypeIdentifiers
import CoreText

struct ShareableNote: Hashable, Sendable {
    let url: String
    let title: String

    var displayTitle: String { title.isEmpty ? "Untitled" : title }
}

@MainActor
enum NoteShare {
    enum Format: String {
        case markdown, html, rtf, plainText, pdf

        var fileExtension: String {
            switch self {
            case .markdown: "md"
            case .html: "html"
            case .rtf: "rtf"
            case .plainText: "txt"
            case .pdf: "pdf"
            }
        }
    }

    enum ShareError: Error {
        case noteUnavailable
    }

    static func fileURL(_ format: Format, note: ShareableNote) async throws -> URL {
        let model = NotesModel.shared
        guard let snapshot = await model.spansSnapshot(for: note.url) else {
            throw ShareError.noteUnavailable
        }
        let json = snapshot.spansJson
        let spans = await Task.detached { SpanNode.decodeList(json) }.value
        let title = note.displayTitle
        let data: Data
        switch format {
        case .markdown:
            data = Data(RichTextClipboard.markdown(from: spans).utf8)
        case .plainText:
            data = Data(LushDocuments.plainText(spans).utf8)
        case .html:
            let images = await inlineImages(for: spans, model: model)
            data = await Task.detached {
                Data(
                    NoteExporter.htmlDocument(
                        title: title,
                        spans: spans,
                        inlineImages: images
                    ).utf8
                )
            }.value
        case .rtf:
            data = try NoteExporter.rtfData(from: spans)
        case .pdf:
            data = try await NoteExporter.pdfData(from: spans, title: title)
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lush-share-\(UUID().uuidString)", isDirectory: true)
        let safe = title
            .components(separatedBy: CharacterSet(charactersIn: "/\\:"))
            .joined(separator: "-")
        let file = dir
            .appendingPathComponent(safe)
            .appendingPathExtension(format.fileExtension)
        try await Task.detached {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: file)
        }.value
        return file
    }

    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "avif", "heic", "heif",
    ]

    private static func inlineImages(for spans: [SpanNode], model: NotesModel) async -> [String: Data] {
        var images: [String: Data] = [:]
        for span in spans {
            guard case .block(let block) = span, block.isEmbedBlock,
                  let assetUrl = block.embedUrl
            else { continue }
            let name = (await model.assetInfo(assetUrl))?.name ?? ""
            let ext = (name as NSString).pathExtension.lowercased()
            guard imageExtensions.contains(ext) else { continue }
            if let data = await model.assetBytes(assetUrl) {
                images[assetUrl] = data
            }
        }
        return images
    }
}

extension UTType {
    static let noteMarkdown = UTType(filenameExtension: "md", conformingTo: .plainText) ?? .plainText
}

struct MarkdownNoteFile: Transferable {
    let note: ShareableNote

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .noteMarkdown) { item in
            SentTransferredFile(try await NoteShare.fileURL(.markdown, note: item.note))
        }
    }
}

struct HtmlNoteFile: Transferable {
    let note: ShareableNote

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .html) { item in
            SentTransferredFile(try await NoteShare.fileURL(.html, note: item.note))
        }
    }
}

struct RtfNoteFile: Transferable {
    let note: ShareableNote

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .rtf) { item in
            SentTransferredFile(try await NoteShare.fileURL(.rtf, note: item.note))
        }
    }
}

struct PlainTextNoteFile: Transferable {
    let note: ShareableNote

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { item in
            SentTransferredFile(try await NoteShare.fileURL(.plainText, note: item.note))
        }
    }
}

struct PdfNoteFile: Transferable {
    let note: ShareableNote

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .pdf) { item in
            SentTransferredFile(try await NoteShare.fileURL(.pdf, note: item.note))
        }
    }
}

/// The five format rows of a "Share As" menu, each opening the system share
/// sheet with a file generated on demand.
struct NoteShareLinks: View {
    let note: ShareableNote

    var body: some View {
        ShareLink(item: MarkdownNoteFile(note: note), preview: preview) {
            Label("Markdown", systemImage: "number")
        }
        ShareLink(item: HtmlNoteFile(note: note), preview: preview) {
            Label("HTML", systemImage: "chevron.left.forwardslash.chevron.right")
        }
        ShareLink(item: RtfNoteFile(note: note), preview: preview) {
            Label("Rich Text", systemImage: "doc.richtext")
        }
        ShareLink(item: PlainTextNoteFile(note: note), preview: preview) {
            Label("Plain Text", systemImage: "doc.plaintext")
        }
        ShareLink(item: PdfNoteFile(note: note), preview: preview) {
            Label("PDF", systemImage: "doc.text.image")
        }
    }

    private var preview: SharePreview<Never, Never> {
        SharePreview(note.displayTitle)
    }
}
