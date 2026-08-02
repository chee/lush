#if os(macOS)
import AppKit

/// Pulls every note out of Apple Notes over Apple Events (needs the
/// com.apple.security.automation.apple-events entitlement and the user's
/// one-time consent) and converts the HTML bodies into span documents.
enum AppleNotesImporter {
    struct ImportedNote {
        let folder: String
        let name: String
        let modified: Date
        let html: String
    }

    static func fetchNotes() throws -> [ImportedNote] {
        let source = """
        set fieldSep to character id 31
        set noteSep to character id 30
        set out to ""
        tell application "Notes"
            repeat with f in folders
                set fName to name of f
                repeat with n in notes of f
                    try
                        set agoSecs to (current date) - (modification date of n)
                        set out to out & fName & fieldSep & (name of n) & fieldSep & agoSecs & fieldSep & (body of n) & noteSep
                    end try
                end repeat
            end repeat
        end tell
        return out
        """
        guard let script = NSAppleScript(source: source) else {
            throw importError("couldn't build the Notes script")
        }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = errorInfo[NSAppleScript.errorMessage] as? String
                ?? "Notes automation was refused"
            throw importError(message)
        }
        guard let raw = result.stringValue else { return [] }
        let now = Date()
        return raw
            .split(separator: "\u{1E}", omittingEmptySubsequences: true)
            .compactMap { chunk in
                let parts = chunk.split(
                    separator: "\u{1F}",
                    maxSplits: 3,
                    omittingEmptySubsequences: false
                )
                guard parts.count == 4 else { return nil }
                let ago = TimeInterval(parts[2]) ?? 0
                return ImportedNote(
                    folder: String(parts[0]),
                    name: String(parts[1]),
                    modified: now.addingTimeInterval(-ago),
                    html: String(parts[3])
                )
            }
    }

    private static func importError(_ message: String) -> NSError {
        NSError(
            domain: "AppleNotesImporter",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    // MARK: HTML → spans

    @MainActor
    static func spans(fromHTML html: String) -> [SpanNode] {
        guard let data = html.data(using: .utf8),
              let attributed = NSAttributedString(
                html: data,
                options: [.characterEncoding: String.Encoding.utf8.rawValue],
                documentAttributes: nil
              )
        else { return [] }
        return convert(attributed)
    }

    private static let listMarker = /^\s*(?:[•◦▪‣∙*-]|\d{1,4}[.)])\s*/

    private static func convert(_ attr: NSAttributedString) -> [SpanNode] {
        var spans: [SpanNode] = []
        let str = attr.string as NSString
        var location = 0
        while location < str.length {
            let paragraph = str.paragraphRange(for: NSRange(location: location, length: 0))
            guard paragraph.length > 0 else { break }
            location = NSMaxRange(paragraph)

            var content = paragraph
            if str.character(at: NSMaxRange(paragraph) - 1) == 0x0A {
                content.length -= 1
            }
            let startAttrs = attr.attributes(at: paragraph.location, effectiveRange: nil)
            let style = startAttrs[.paragraphStyle] as? NSParagraphStyle
            var block = BlockValue.paragraph
            if let lists = style?.textLists, !lists.isEmpty {
                let ordered = lists.last.map {
                    String(describing: $0.markerFormat).contains("decimal")
                } ?? false
                block = BlockValue(type: ordered ? "ordered-list-item" : "unordered-list-item")
                if content.length > 0 {
                    let text = str.substring(with: content)
                    if let marker = text.prefixMatch(of: listMarker) {
                        let markerLength = (String(marker.output) as NSString).length
                        content.location += markerLength
                        content.length -= markerLength
                    }
                }
            } else if let font = startAttrs[.font] as? NSFont,
                      font.hasBoldTrait, font.pointSize >= 17, content.length > 0 {
                block = .heading(level: font.pointSize >= 22 ? 1 : 2)
            }
            spans.append(.block(block))

            guard content.length > 0 else { continue }
            attr.enumerateAttributes(in: content) { runAttrs, runRange, _ in
                let text = str.substring(with: runRange)
                    .replacingOccurrences(of: "\u{FFFC}", with: "")
                guard !text.isEmpty else { return }
                spans.append(.text(text, RichText.marks(from: runAttrs, block: block)))
            }
        }
        return spans
    }
}
#endif
