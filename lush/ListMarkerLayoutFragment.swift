#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// TextKit 2 home of the list/quote decorations. Markers are pure decoration —
/// they never exist in the text, so the automerge round-trip can't be
/// corrupted by them.
enum MarkerDrawing {
    static let decoratedTypes: Set<String> = [
        "blockquote", "unordered-list-item", "ordered-list-item", "todo-list-item",
    ]

    static func marker(
        block: BlockValue,
        ordinal: Int,
        font itemFont: PFont,
        indent: CGFloat,
        lineRect: CGRect,
        origin: CGPoint
    ) {
        let baseline = origin.y + lineRect.minY + itemFont.ascender
        let diameter: CGFloat = 6.5
        switch block.type {
        case "todo-list-item":
            let side = itemFont.pointSize * 0.82
            let rect = CGRect(
                x: origin.x + indent - side - 6,
                y: baseline - itemFont.xHeight / 2 - side / 2,
                width: side,
                height: side
            )
            checkbox(in: rect, checked: block.isChecked)
        case "unordered-list-item":
            let rect = CGRect(
                x: origin.x + indent - diameter - 5,
                y: baseline - itemFont.xHeight / 2 - diameter / 2,
                width: diameter,
                height: diameter
            )
            PColor.pLabel.setFill()
            #if os(macOS)
            NSBezierPath(ovalIn: rect).fill()
            #else
            UIBezierPath(ovalIn: rect).fill()
            #endif
        default:
            let marker = "\(ordinal)."
            let font = PFont.monospacedDigitSystemFont(ofSize: RichText.bodySize, weight: .regular)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: PColor.pLabel,
            ]
            let markerWidth = (marker as NSString).size(withAttributes: attrs).width
            let point = CGPoint(
                x: origin.x + indent - markerWidth - 6,
                y: baseline - font.ascender
            )
            marker.draw(at: point, withAttributes: attrs)
        }
    }

    static func quoteAccent(lineRect: CGRect, origin: CGPoint) {
        let width: CGFloat = 3
        let height = max(0, lineRect.height - 2)
        let rect = CGRect(
            x: origin.x + 1,
            y: origin.y + lineRect.minY + 1,
            width: width,
            height: height
        )

        PColor.pTint.setFill()
        #if os(macOS)
        NSBezierPath(roundedRect: rect, xRadius: width / 2, yRadius: width / 2).fill()
        #else
        UIBezierPath(roundedRect: rect, cornerRadius: width / 2).fill()
        #endif
    }

    /// The to-do box: an empty rounded square, or a filled one with a tick.
    /// Clicking it is handled by the text view (`toggleTodo(at:)`).
    static func checkbox(in rect: CGRect, checked: Bool) {
        let square = rect.insetBy(dx: 0.75, dy: 0.75)
        #if os(macOS)
        let box = NSBezierPath(roundedRect: square, xRadius: 3, yRadius: 3)
        #else
        let box = UIBezierPath(roundedRect: square, cornerRadius: 3)
        #endif
        guard checked else {
            box.lineWidth = 1.5
            PColor.pSecondaryLabel.setStroke()
            box.stroke()
            return
        }
        PColor.pTint.setFill()
        box.fill()
        let tick = PBezierPath()
        tick.move(to: CGPoint(x: rect.minX + rect.width * 0.24, y: rect.midY + rect.height * 0.02))
        tick.line(to: CGPoint(x: rect.minX + rect.width * 0.43, y: rect.maxY - rect.height * 0.24))
        tick.line(to: CGPoint(x: rect.minX + rect.width * 0.76, y: rect.minY + rect.height * 0.24))
        tick.lineWidth = max(1.5, rect.width * 0.14)
        PColor.pOnTint.setStroke()
        tick.stroke()
    }
}

/// 1-based position among the contiguous run of ordered items with the same
/// nesting.
func listOrdinal(of location: Int, in storage: NSTextStorage) -> Int {
    let str = storage.string as NSString
    guard let box = storage.attribute(.amBlock, at: location, effectiveRange: nil) as? BlockBox
    else { return 1 }
    let parents = box.value.parents
    var count = 1
    var cursor = location
    while cursor > 0 {
        let previous = str.paragraphRange(for: NSRange(location: cursor - 1, length: 0))
        guard previous.length > 0,
              let prevBox = storage.attribute(.amBlock, at: previous.location, effectiveRange: nil) as? BlockBox,
              prevBox.value.type == "ordered-list-item",
              prevBox.value.parents == parents
        else { break }
        count += 1
        cursor = previous.location
    }
    return count
}

final class ListMarkerLayoutFragment: NSTextLayoutFragment {
    /// The trailing empty line (doc ends in `\n`) has no characters to hang
    /// attributes on, so its marker comes from the view's typing attributes
    /// via this hook.
    var typingAttributesProvider: (() -> [NSAttributedString.Key: Any]?)?

    private var paragraphAttributes: [NSAttributedString.Key: Any]? {
        guard let paragraph = textElement as? NSTextParagraph,
              paragraph.attributedString.length > 0
        else { return nil }
        return paragraph.attributedString.attributes(at: 0, effectiveRange: nil)
    }

    private func decoratedBlock(_ attrs: [NSAttributedString.Key: Any]?) -> BlockValue? {
        guard let box = attrs?[.amBlock] as? BlockBox,
              MarkerDrawing.decoratedTypes.contains(box.value.type)
        else { return nil }
        return box.value
    }

    private var isLastFragment: Bool {
        guard let element = textElement,
              let contentManager = element.textContentManager,
              let elementRange = element.elementRange
        else { return false }
        return elementRange.endLocation.compare(contentManager.documentRange.endLocation) == .orderedSame
    }

    /// TextKit 2's `extraLineFragmentRect`: the last fragment carries an
    /// empty extra line when the document ends in a newline.
    private var trailingEmptyLine: NSTextLineFragment? {
        guard let last = textLineFragments.last, last.characterRange.length == 0
        else { return nil }
        return isLastFragment ? last : nil
    }

    override var renderingSurfaceBounds: CGRect {
        let bounds = super.renderingSurfaceBounds
        var indent: CGFloat = 0
        if let attrs = paragraphAttributes, decoratedBlock(attrs) != nil {
            indent = (attrs[.paragraphStyle] as? NSParagraphStyle)?.firstLineHeadIndent ?? 20
        }
        if trailingEmptyLine != nil, let typing = typingAttributesProvider?(), decoratedBlock(typing) != nil {
            let typingIndent = (typing[.paragraphStyle] as? NSParagraphStyle)?.firstLineHeadIndent ?? 20
            indent = max(indent, typingIndent)
        }
        guard indent > 0 else { return bounds }
        // The fragment hugs the text, so container x = 0 sits at local
        // -(indent + lineFragmentPadding); markers live left of the text.
        return bounds.union(CGRect(x: -(indent + 24), y: bounds.minY, width: indent + 24, height: bounds.height))
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        super.draw(at: point, in: context)

        #if os(macOS)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }
        #else
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }
        #endif

        let origin = CGPoint(x: -layoutFragmentFrame.minX, y: 0)
        let attrs = paragraphAttributes
        if let block = decoratedBlock(attrs), let attrs {
            let contentLines = textLineFragments.filter { $0.characterRange.length > 0 }
            if block.type == "blockquote" {
                let lineRect = contentLines.reduce(CGRect.null) { $0.union($1.typographicBounds) }
                if !lineRect.isNull {
                    MarkerDrawing.quoteAccent(lineRect: lineRect, origin: origin)
                }
            } else if let lineRect = contentLines.first?.typographicBounds {
                let font = attrs[.font] as? PFont ?? PFont.systemFont(ofSize: RichText.bodySize)
                let indent = (attrs[.paragraphStyle] as? NSParagraphStyle)?.firstLineHeadIndent ?? 20
                MarkerDrawing.marker(
                    block: block,
                    ordinal: block.type == "ordered-list-item" ? ordinal() : 1,
                    font: font,
                    indent: indent,
                    lineRect: lineRect,
                    origin: origin
                )
            }
        }

        guard let extraLine = trailingEmptyLine,
              let typing = typingAttributesProvider?(),
              let block = decoratedBlock(typing)
        else { return }
        let lineRect = extraLine.typographicBounds
        if block.type == "blockquote" {
            MarkerDrawing.quoteAccent(lineRect: lineRect, origin: origin)
            return
        }
        let font = typing[.font] as? PFont ?? PFont.systemFont(ofSize: RichText.bodySize)
        let indent = (typing[.paragraphStyle] as? NSParagraphStyle)?.firstLineHeadIndent ?? 20
        MarkerDrawing.marker(
            block: block,
            ordinal: block.type == "ordered-list-item" ? trailingOrdinal(block: block) : 1,
            font: font,
            indent: indent,
            lineRect: lineRect,
            origin: origin
        )
    }

    private func storageContext() -> (storage: NSTextStorage, location: Int)? {
        guard let element = textElement,
              let contentStorage = element.textContentManager as? NSTextContentStorage,
              let storage = contentStorage.textStorage,
              let elementRange = element.elementRange
        else { return nil }
        let location = contentStorage.offset(
            from: contentStorage.documentRange.location,
            to: elementRange.location
        )
        return (storage, location)
    }

    private func ordinal() -> Int {
        guard let (storage, location) = storageContext(),
              location >= 0, location < storage.length
        else { return 1 }
        return listOrdinal(of: location, in: storage)
    }

    /// The trailing empty line continues the list above it, if any.
    private func trailingOrdinal(block: BlockValue) -> Int {
        guard let (storage, _) = storageContext(), storage.length > 0 else { return 1 }
        let str = storage.string as NSString
        let previous = str.paragraphRange(for: NSRange(location: storage.length - 1, length: 0))
        guard let prevBox = storage.attribute(.amBlock, at: previous.location, effectiveRange: nil) as? BlockBox,
              prevBox.value.type == "ordered-list-item",
              prevBox.value.parents == block.parents
        else { return 1 }
        return listOrdinal(of: previous.location, in: storage) + 1
    }
}

extension NSTextContentManager {
    func textRange(for range: NSRange) -> NSTextRange? {
        guard let start = location(documentRange.location, offsetBy: range.location),
              let end = location(start, offsetBy: range.length)
        else { return nil }
        return NSTextRange(location: start, end: end)
    }

    func range(for textRange: NSTextRange) -> NSRange {
        NSRange(
            location: offset(from: documentRange.location, to: textRange.location),
            length: offset(from: textRange.location, to: textRange.endLocation)
        )
    }
}

/// Ordinals depend on the run above them, and TextKit 2 doesn't redraw
/// fragments that merely moved, so an edit inside an ordered run must
/// renumber everything below it explicitly.
func invalidateOrderedListRun(
    around location: Int,
    textLayoutManager: NSTextLayoutManager,
    storage: NSTextStorage
) {
    guard storage.length > 0 else { return }
    let str = storage.string as NSString
    let anchor = min(max(location, 0), storage.length - 1)
    let paragraph = str.paragraphRange(for: NSRange(location: anchor, length: 0))

    func isOrdered(_ range: NSRange) -> Bool {
        guard range.length > 0,
              let box = storage.attribute(.amBlock, at: range.location, effectiveRange: nil) as? BlockBox
        else { return false }
        return box.value.type == "ordered-list-item"
    }

    let nextStart = NSMaxRange(paragraph)
    let nextIsOrdered = nextStart < storage.length
        && isOrdered(str.paragraphRange(for: NSRange(location: nextStart, length: 0)))
    guard isOrdered(paragraph) || nextIsOrdered else { return }

    var end = NSMaxRange(paragraph)
    while end < storage.length {
        let next = str.paragraphRange(for: NSRange(location: end, length: 0))
        guard isOrdered(next) else { break }
        end = NSMaxRange(next)
    }
    let run = NSRange(location: paragraph.location, length: end - paragraph.location)
    guard run.length > 0,
          let contentManager = textLayoutManager.textContentManager,
          let textRange = contentManager.textRange(for: run)
    else { return }
    textLayoutManager.invalidateLayout(for: textRange)
}

final class ListMarkerLayoutDelegate: NSObject, NSTextLayoutManagerDelegate {
    var typingAttributesProvider: (() -> [NSAttributedString.Key: Any]?)?

    func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager,
        textLayoutFragmentFor location: NSTextLocation,
        in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        let fragment = ListMarkerLayoutFragment(
            textElement: textElement,
            range: textElement.elementRange
        )
        fragment.typingAttributesProvider = typingAttributesProvider
        return fragment
    }
}
