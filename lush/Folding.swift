#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Folds are keyed by the heading's text and level, not object identity:
/// remote reloads rebuild every BlockBox, and a recycled address could match
/// the wrong heading. Same-text same-level headings fold together.
struct HeadingFoldKey: Hashable {
    let text: String
    let level: Int

    init(paragraph: NSRange, in storage: NSAttributedString, box: BlockBox) {
        text = (storage.string as NSString).substring(with: paragraph)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        level = box.value.headingLevel ?? 1
    }

    init(text: String, level: Int) {
        self.text = text
        self.level = level
    }
}

/// Collapses folded sections and stashed blocks to zero height by
/// substituting empty display paragraphs. The storage — and so the automerge
/// round-trip — is untouched; only layout sees the substitution.
final class FoldingContentDelegate: NSObject, NSTextContentStorageDelegate {
    var foldedHeadings: Set<HeadingFoldKey> = []
    var hideCheckedTodos = false
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
            if hideCheckedTodos, box.value.isChecked {
                let depth = box.value.parents.count
                var end = NSMaxRange(paragraph)
                while end < storage.length {
                    let next = str.paragraphRange(for: NSRange(location: end, length: 0))
                    if next.length == 0 { break }
                    guard let nextBox = storage.attribute(.amBlock, at: next.location, effectiveRange: nil) as? BlockBox,
                          nextBox.value.parents.count > depth
                    else { break }
                    end = NSMaxRange(next)
                }
                ranges.append(NSRange(location: paragraph.location, length: end - paragraph.location))
                location = end
                continue
            }
            guard box.value.type == "heading", !foldedHeadings.isEmpty,
                  foldedHeadings.contains(HeadingFoldKey(paragraph: paragraph, in: storage, box: box))
            else { continue }
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

    /// The substituted paragraph must keep the backing range's exact length:
    /// UITextInput and accessibility read `attributedString(in:)` across the
    /// whole document, and any presentation/backing length divergence sends
    /// TextKit's offset mapping out of bounds (boot NSRangeException on iOS
    /// when the open note has stashed paragraphs). Hiding is purely
    /// stylistic — same characters, ~zero size.
    func textContentStorage(
        _ textContentStorage: NSTextContentStorage,
        textParagraphWith range: NSRange
    ) -> NSTextParagraph? {
        guard hiddenRanges.contains(where: { NSIntersectionRange($0, range).length > 0 }) else {
            return nil
        }
        guard let backing = textContentStorage.textStorage,
              NSMaxRange(range) <= backing.length
        else { return nil }
        let text = (backing.string as NSString).substring(with: range)
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = 0.01
        style.maximumLineHeight = 0.01
        style.lineSpacing = 0
        style.paragraphSpacing = 0
        style.paragraphSpacingBefore = 0
        return NSTextParagraph(attributedString: NSAttributedString(
            string: text,
            attributes: [
                .font: PFont.systemFont(ofSize: 0.01),
                .foregroundColor: PColor.clear,
                .paragraphStyle: style,
            ]
        ))
    }
}
