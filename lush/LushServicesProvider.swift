import Foundation

#if os(macOS)
import AppKit
import UniformTypeIdentifiers

@MainActor
final class LushServicesProvider: NSObject {
    static let shared = LushServicesProvider()

    @objc func addSelectionToQuickNote(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        let text = pasteboard.lushTextPayload()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error.pointee = "No text was available to add to Quick Note."
            return
        }
        Task { _ = await NotesModel.shared.appendToQuickNote(text) }
    }

    @objc func importSelectionIntoLush(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        let payloads = pasteboard.lushIncomingPayloads()
        guard !payloads.isEmpty else {
            error.pointee = "No text or files were available to import into Lush."
            return
        }
        NotesModel.shared.pendingIncoming = IncomingContent(payload: .batch(payloads))
        AppRouter.shared.pending = .capture
    }
}

private extension NSPasteboard {
    func lushTextPayload() -> String {
        if let text = string(forType: .string) {
            return text
        }
        let fileText = lushFileURLs().map(\.path).joined(separator: "\n")
        return fileText
    }

    func lushIncomingPayloads() -> [IncomingContent.Payload] {
        var payloads: [IncomingContent.Payload] = []
        if let text = string(forType: .string),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payloads.append(.text(text))
        }
        payloads += lushFileURLs().map { .file($0) }
        return payloads
    }

    func lushFileURLs() -> [URL] {
        readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL] ?? []
    }
}
#endif
