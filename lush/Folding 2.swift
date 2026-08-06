#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Collapses folded sections and stashed blocks to zero height by
/// substituting empty display paragraphs. The storage — and so the automerge
/// round-trip — is untouched; only layout sees the substitution.
final class FoldingContentDelegate: NSObject, NSTextContentStorageDelegate {
    var foldedHeadings: Set<ObjectIdentifier> = []
    private(set) var hiddenRanges: [NSRange] = []

    func refresh(storage: NSAttributedString) {
        var ranges: [NSRange] = []
        let str = storage.string as NSString
        var location = 0
        while location < storage.length {
            let paragraph = str.paragraphRange(for: NSRange(location: location, length: 0))
            if paragraph.length == 0 { break }
            location = NSMaxRange(paragraph)
            guard let box = storage.attribute(.amBlock, at: paragraph.location, effectiveRange: nil) as? BlockBox
            else { continue }
            if box.value.attrs["stash"] != nil {
                ranges.append(paragraph)
                continue
            }
            guard box.value.type == "heading", foldedHeadings.contains(ObjectIdentifier(box)) else { continue }
            let level = box.value.headingLevel ?? 1
            var end = NSMaxRange(paragraph)
            while end < storage.length {
                let next = str.paragraphRange(for: NSRange(location: end, length: 0))
                if next.length == 0 { break }
                if let nextBox = storage.attribute(.amBlock, at: next.location, effectiveRange: nil) as? BlockBox,
                   nextBox.value.type == "heading",
                   (nextBox.value.headingLevel ?? 1) <= level {
                    break
                }
                end = NSMaxRange(next)
            }
            if end > NSMaxRange(paragraph) {
                ranges.append(NSRange(location: NSMaxRange(paragraph), length: end - NSMaxRange(paragraph)))
                location = end
            }
        }
        hiddenRanges = ranges
    }

    func isHidden(_ location: Int) -> Bool {
        hiddenRanges.contains { NSLocationInRange(location, $0) }
    }

    func textContentStorage(
        _ textContentStorage: NSTextContentStorage,
        textParagraphWith range: NSRange
    ) -> NSTextParagraph? {
        guard hiddenRanges.contains(where: { NSIntersectionRange($0, range).length > 0 }) else {
            return nil
        }
        return NSTextParagraph(attributedString: NSAttributedString(
            string: "\u{200B}",
            attributes: [.font: PFont.systemFont(ofSize: 0.01)]
        ))
    }
}
