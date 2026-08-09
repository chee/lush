#if os(macOS)
import AppKit
#else
import UIKit
#endif

#if !os(macOS)
private extension UIBezierPath {
    func curve(to endPoint: CGPoint, controlPoint1: CGPoint, controlPoint2: CGPoint) {
        addCurve(to: endPoint, controlPoint1: controlPoint1, controlPoint2: controlPoint2)
    }
}
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
            let side = itemFont.pointSize * 0.94
            let rect = CGRect(
                x: origin.x + indent - side - 6,
                y: baseline - itemFont.xHeight / 2 - side / 2,
                width: side,
                height: side
            )
            checkbox(in: rect, state: block.todoState)
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

    static var quoteBackground: PColor {
        #if os(macOS)
        PColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? PColor(rgb: 0xFFFFFF, alpha: 0.035)
                : PColor(rgb: 0xFFF0D6, alpha: 0.36)
        }
        #else
        PColor { traits in
            traits.userInterfaceStyle == .dark
                ? PColor(rgb: 0xFFFFFF, alpha: 0.035)
                : PColor(rgb: 0xFFF0D6, alpha: 0.36)
        }
        #endif
    }

    static var quoteAccent: PColor {
        #if os(macOS)
        PColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? PColor(rgb: 0xFFB0D2, alpha: 0.95)
                : PColor(rgb: 0xFF4D97, alpha: 0.9)
        }
        #else
        PColor { traits in
            traits.userInterfaceStyle == .dark
                ? PColor(rgb: 0xFFB0D2, alpha: 0.95)
                : PColor(rgb: 0xFF4D97, alpha: 0.9)
        }
        #endif
    }

    private static func quoteRects(lineRect: CGRect, origin: CGPoint, containerWidth: CGFloat) -> (background: CGRect, accent: CGRect) {
        // lineRect is already fragment-local; only container-space values
        // (the 2.5 left margin, containerWidth) need origin applied
        let contentLeft = lineRect.minX
        let left = max(origin.x + 2.5, contentLeft - 18)
        let right = origin.x + containerWidth - 24
        let background = CGRect(
            x: left,
            y: origin.y + lineRect.minY - 2,
            width: max(0, right - left),
            height: lineRect.height + 4
        )
        let accent = CGRect(
            x: background.minX + 2,
            y: background.minY + 4,
            width: 3.5,
            height: max(0, background.height - 8)
        )
        return (background, accent)
    }

    private static func roundedBlockPath(rect: CGRect, radius: CGFloat, roundTop: Bool, roundBottom: Bool) -> PBezierPath {
        let r = min(radius, rect.width / 2, rect.height / 2)
        let c = r * 0.5522847498
        let path = PBezierPath()
        path.move(to: CGPoint(x: rect.minX + (roundTop ? r : 0), y: rect.minY))
        path.line(to: CGPoint(x: rect.maxX - (roundTop ? r : 0), y: rect.minY))
        if roundTop {
            path.curve(
                to: CGPoint(x: rect.maxX, y: rect.minY + r),
                controlPoint1: CGPoint(x: rect.maxX - r + c, y: rect.minY),
                controlPoint2: CGPoint(x: rect.maxX, y: rect.minY + r - c)
            )
        }
        path.line(to: CGPoint(x: rect.maxX, y: rect.maxY - (roundBottom ? r : 0)))
        if roundBottom {
            path.curve(
                to: CGPoint(x: rect.maxX - r, y: rect.maxY),
                controlPoint1: CGPoint(x: rect.maxX, y: rect.maxY - r + c),
                controlPoint2: CGPoint(x: rect.maxX - r + c, y: rect.maxY)
            )
        }
        path.line(to: CGPoint(x: rect.minX + (roundBottom ? r : 0), y: rect.maxY))
        if roundBottom {
            path.curve(
                to: CGPoint(x: rect.minX, y: rect.maxY - r),
                controlPoint1: CGPoint(x: rect.minX + r - c, y: rect.maxY),
                controlPoint2: CGPoint(x: rect.minX, y: rect.maxY - r + c)
            )
        }
        path.line(to: CGPoint(x: rect.minX, y: rect.minY + (roundTop ? r : 0)))
        if roundTop {
            path.curve(
                to: CGPoint(x: rect.minX + r, y: rect.minY),
                controlPoint1: CGPoint(x: rect.minX, y: rect.minY + r - c),
                controlPoint2: CGPoint(x: rect.minX + r - c, y: rect.minY)
            )
        }
        path.close()
        return path
    }

    static func quoteBackground(lineRect: CGRect, origin: CGPoint, containerWidth: CGFloat, first: Bool = true, last: Bool = true) {
        var rect = quoteRects(lineRect: lineRect, origin: origin, containerWidth: containerWidth).background
        if !first {
            rect.origin.y += 2
            rect.size.height -= 2
        }
        if !last {
            rect.size.height -= 2
        }
        quoteBackground.setFill()
        roundedBlockPath(rect: rect, radius: 6, roundTop: first, roundBottom: last).fill()
    }

    static func quoteAccent(lineRect: CGRect, origin: CGPoint, containerWidth: CGFloat, first: Bool = true, last: Bool = true) {
        var rect = quoteRects(lineRect: lineRect, origin: origin, containerWidth: containerWidth).accent
        if !first {
            rect.origin.y -= 4
            rect.size.height += 4
        }
        if !last {
            rect.size.height += 4
        }
        quoteAccent.setFill()
        #if os(macOS)
        NSBezierPath(roundedRect: rect, xRadius: first || last ? 1.75 : 0, yRadius: first || last ? 1.75 : 0).fill()
        #else
        UIBezierPath(roundedRect: rect, cornerRadius: first || last ? 1.75 : 0).fill()
        #endif
    }

    static var changeBarColor: PColor {
        #if os(macOS)
        PColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? PColor(rgb: 0xDA702C, alpha: 0.85)
                : PColor(rgb: 0xBC5215, alpha: 0.85)
        }
        #else
        PColor { traits in
            traits.userInterfaceStyle == .dark
                ? PColor(rgb: 0xDA702C, alpha: 0.85)
                : PColor(rgb: 0xBC5215, alpha: 0.85)
        }
        #endif
    }

    /// A folded heading's disclosure triangle, drawn in the container inset.
    static func foldChevron(lineRect: CGRect, origin: CGPoint, font: PFont) {
        let size = font.pointSize * 0.42
        let midY = origin.y + lineRect.minY + font.ascender - font.xHeight / 2
        let path = PBezierPath()
        path.move(to: CGPoint(x: origin.x - 15, y: midY - size))
        path.line(to: CGPoint(x: origin.x - 15 + size * 1.4, y: midY))
        path.line(to: CGPoint(x: origin.x - 15, y: midY + size))
        path.close()
        PColor.pTint.setFill()
        path.fill()
    }

    /// History viewer: this paragraph differs from the parent version.
    static func changeBar(lineRect: CGRect, origin: CGPoint) {
        let rect = CGRect(
            x: origin.x + 2,
            y: origin.y + lineRect.minY + 1,
            width: 3,
            height: max(0, lineRect.height - 2)
        )
        changeBarColor.setFill()
        #if os(macOS)
        NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
        #else
        UIBezierPath(roundedRect: rect, cornerRadius: 1.5).fill()
        #endif
    }

    /// The to-do box: an empty rounded square, or a filled one carrying the
    /// glyph for its state. Clicking it is handled by the text view
    /// (`toggleTodo(at:)`); right-click picks the state.
    static func checkbox(in rect: CGRect, state: TodoState) {
        let square = rect.insetBy(dx: 0.5, dy: 0.5)
        let radius = square.width * 0.34
        #if os(macOS)
        let box = NSBezierPath(roundedRect: square, xRadius: radius, yRadius: radius)
        #else
        let box = UIBezierPath(roundedRect: square, cornerRadius: radius)
        #endif
        switch state {
        case .open:
            box.lineWidth = 1
            PColor.pSecondaryLabel.withAlphaComponent(0.5).setStroke()
            box.stroke()
            return
        case .checked:
            PColor.pTint.setFill()
            box.fill()
        case .canceled:
            PColor.pSecondaryLabel.withAlphaComponent(0.55).setFill()
            box.fill()
        case .pending:
            box.lineWidth = 1
            PColor.pSecondaryLabel.withAlphaComponent(0.5).setStroke()
            box.stroke()
        }

        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }
        let glyph = PBezierPath()
        switch state {
        case .open:
            return
        case .checked:
            glyph.move(to: point(0.184, 0.500))
            glyph.line(to: point(0.381, 0.698))
            glyph.line(to: point(0.816, 0.263))
        case .canceled:
            glyph.move(to: point(0.7375, 0.2625))
            glyph.line(to: point(0.2625, 0.7375))
            glyph.move(to: point(0.2625, 0.2625))
            glyph.line(to: point(0.7375, 0.7375))
        case .pending:
            glyph.move(to: point(0.2625, 0.7375))
            glyph.line(to: point(0.7375, 0.2625))
        }
        glyph.lineWidth = max(1.4, rect.width * 0.12)
        glyph.lineCapStyle = .round
        glyph.lineJoinStyle = .round
        (state == .pending ? PColor.pTint : PColor.pOnTint).setStroke()
        glyph.stroke()
    }
}

/// 1-based position among the contiguous run of ordered items with the same
/// nesting.
func listOrdinal(of location: Int, in storage: NSTextStorage) -> Int {
    let str = storage.string as NSString
    guard location >= 0,
          location < storage.length,
          let box = storage.attribute(.amBlock, at: location, effectiveRange: nil) as? BlockBox
    else { return 1 }
    let parents = box.value.parents
    var count = 1
    var cursor = location
    while cursor > 0 {
        let previous = str.paragraphRange(for: NSRange(location: cursor - 1, length: 0))
        guard previous.length > 0,
              previous.location >= 0,
              previous.location < storage.length,
              let prevBox = storage.attribute(.amBlock, at: previous.location, effectiveRange: nil) as? BlockBox
        else { break }
        let prevParents = prevBox.value.parents
        if prevBox.value.type == "ordered-list-item", prevParents == parents {
            count += 1
            cursor = previous.location
        } else if prevParents.count > parents.count,
                  prevParents.prefix(parents.count).elementsEqual(parents),
                  MarkerDrawing.decoratedTypes.contains(prevParents[parents.count]) {
            cursor = previous.location
        } else {
            break
        }
    }
    return count
}

final class ListMarkerLayoutFragment: NSTextLayoutFragment {
    /// The trailing empty line (doc ends in `\n`) has no characters to hang
    /// attributes on, so its marker comes from the view's typing attributes
    /// via this hook.
    var typingAttributesProvider: (() -> [NSAttributedString.Key: Any]?)?
    var foldedHeadingsProvider: (() -> Set<HeadingFoldKey>)?
    var selectionProvider: (() -> (range: NSRange, color: PColor)?)?

    private var headingFoldKey: HeadingFoldKey? {
        guard let paragraph = textElement as? NSTextParagraph,
              let box = paragraphAttributes?[.amBlock] as? BlockBox,
              box.value.type == "heading"
        else { return nil }
        return HeadingFoldKey(
            text: paragraph.attributedString.string
                .trimmingCharacters(in: .whitespacesAndNewlines),
            level: box.value.headingLevel ?? 1
        )
    }

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
        if drawsCodeCard, let width = textLayoutManager?.textContainer?.size.width, width > 0 {
            return bounds.union(CGRect(
                x: -40,
                y: bounds.minY - CodeHighlight.cardVerticalPadding,
                width: width + 80,
                height: bounds.height + CodeHighlight.cardVerticalPadding * 2
            ))
        }
        if drawsQuoteBackground, let width = textLayoutManager?.textContainer?.size.width, width > 0 {
            // the fragment is inset by the quote indent, so container x = 0
            // sits at local -(indent + padding) — reach past it or the card's
            // left edge and the accent bar clip away
            let indent = (paragraphAttributes?[.paragraphStyle] as? NSParagraphStyle)?.firstLineHeadIndent ?? 16
            return bounds.union(CGRect(
                x: -(indent + 32),
                y: bounds.minY - 4,
                width: width + (indent + 32) * 2,
                height: bounds.height + 8
            ))
        }
        var indent: CGFloat = 0
        if let attrs = paragraphAttributes, decoratedBlock(attrs) != nil {
            indent = (attrs[.paragraphStyle] as? NSParagraphStyle)?.firstLineHeadIndent ?? 20
        }
        if trailingEmptyLine != nil, let typing = typingAttributesProvider?(), decoratedBlock(typing) != nil {
            let typingIndent = (typing[.paragraphStyle] as? NSParagraphStyle)?.firstLineHeadIndent ?? 20
            indent = max(indent, typingIndent)
        }
        if paragraphAttributes?[.amChanged] != nil {
            indent = max(indent, 12)
        }
        if let key = headingFoldKey,
           foldedHeadingsProvider?().contains(key) == true {
            indent = max(indent, 12)
        }
        guard indent > 0 else { return bounds }
        // The fragment hugs the text, so container x = 0 sits at local
        // -(indent + lineFragmentPadding); markers live left of the text.
        return bounds.union(CGRect(x: -(indent + 24), y: bounds.minY, width: indent + 24, height: bounds.height))
    }

    private var isCodeBlock: Bool {
        (paragraphAttributes?[.amBlock] as? BlockBox)?.value.type == "code-block"
    }

    private var isTypingCodeBlockOnTrailingLine: Bool {
        guard trailingEmptyLine != nil,
              let box = typingAttributesProvider?()?[.amBlock] as? BlockBox
        else { return false }
        return box.value.type == "code-block"
    }

    private var isQuoteBlock: Bool {
        (paragraphAttributes?[.amBlock] as? BlockBox)?.value.type == "blockquote"
    }

    private var isTypingQuoteBlockOnTrailingLine: Bool {
        guard trailingEmptyLine != nil,
              let box = typingAttributesProvider?()?[.amBlock] as? BlockBox
        else { return false }
        return box.value.type == "blockquote"
    }

    private var drawsCodeCard: Bool {
        isCodeBlock || isTypingCodeBlockOnTrailingLine
    }

    private var drawsQuoteBackground: Bool {
        isQuoteBlock || isTypingQuoteBlockOnTrailingLine
    }

    private func codeRunEdges() -> (first: Bool, last: Bool) {
        guard let (storage, location) = storageContext(), storage.length > 0 else {
            return (true, true)
        }
        let str = storage.string as NSString
        let anchor = min(location, storage.length - 1)
        let paragraph = str.paragraphRange(for: NSRange(location: anchor, length: 0))
        var first = true
        if paragraph.location > 0 {
            let previous = str.paragraphRange(for: NSRange(location: paragraph.location - 1, length: 0))
            first = !CodeHighlight.isCodeParagraph(previous, language: nil, in: storage)
        }
        var last = true
        let end = NSMaxRange(paragraph)
        if end < storage.length {
            let next = str.paragraphRange(for: NSRange(location: end, length: 0))
            last = !CodeHighlight.isCodeParagraph(next, language: nil, in: storage)
        }
        return (first, last)
    }

    private func quoteRunEdges() -> (first: Bool, last: Bool) {
        guard let (storage, location) = storageContext(),
              storage.length > 0,
              let box = paragraphAttributes?[.amBlock] as? BlockBox
        else { return (true, true) }
        let str = storage.string as NSString
        let anchor = min(location, storage.length - 1)
        let paragraph = str.paragraphRange(for: NSRange(location: anchor, length: 0))

        func isMatchingQuote(_ range: NSRange) -> Bool {
            guard range.length > 0,
                  range.location >= 0,
                  range.location < storage.length,
                  let other = storage.attribute(.amBlock, at: range.location, effectiveRange: nil) as? BlockBox
            else { return false }
            return other.value.type == "blockquote" && other.value.parents == box.value.parents
        }

        var first = true
        if paragraph.location > 0 {
            let previous = str.paragraphRange(for: NSRange(location: paragraph.location - 1, length: 0))
            first = !isMatchingQuote(previous)
        }

        var last = true
        let end = NSMaxRange(paragraph)
        if end < storage.length {
            let next = str.paragraphRange(for: NSRange(location: end, length: 0))
            last = !isMatchingQuote(next)
        }
        return (first, last)
    }

    private func codeCardPath(
        rect: CGRect,
        radius: CGFloat,
        roundTop: Bool,
        roundBottom: Bool
    ) -> PBezierPath {
        let r = min(radius, rect.width / 2, rect.height / 2)
        let c = r * 0.5522847498
        let path = PBezierPath()
        path.move(to: CGPoint(x: rect.minX + (roundTop ? r : 0), y: rect.minY))
        path.line(to: CGPoint(x: rect.maxX - (roundTop ? r : 0), y: rect.minY))
        if roundTop {
            path.curve(
                to: CGPoint(x: rect.maxX, y: rect.minY + r),
                controlPoint1: CGPoint(x: rect.maxX - r + c, y: rect.minY),
                controlPoint2: CGPoint(x: rect.maxX, y: rect.minY + r - c)
            )
        }
        path.line(to: CGPoint(x: rect.maxX, y: rect.maxY - (roundBottom ? r : 0)))
        if roundBottom {
            path.curve(
                to: CGPoint(x: rect.maxX - r, y: rect.maxY),
                controlPoint1: CGPoint(x: rect.maxX, y: rect.maxY - r + c),
                controlPoint2: CGPoint(x: rect.maxX - r + c, y: rect.maxY)
            )
        }
        path.line(to: CGPoint(x: rect.minX + (roundBottom ? r : 0), y: rect.maxY))
        if roundBottom {
            path.curve(
                to: CGPoint(x: rect.minX, y: rect.maxY - r),
                controlPoint1: CGPoint(x: rect.minX + r - c, y: rect.maxY),
                controlPoint2: CGPoint(x: rect.minX, y: rect.maxY - r + c)
            )
        }
        path.line(to: CGPoint(x: rect.minX, y: rect.minY + (roundTop ? r : 0)))
        if roundTop {
            path.curve(
                to: CGPoint(x: rect.minX + r, y: rect.minY),
                controlPoint1: CGPoint(x: rect.minX, y: rect.minY + r - c),
                controlPoint2: CGPoint(x: rect.minX + r - c, y: rect.minY)
            )
        }
        path.close()
        return path
    }

    private func codeCardStrokePath(
        rect: CGRect,
        radius: CGFloat,
        roundTop: Bool,
        roundBottom: Bool
    ) -> PBezierPath {
        let r = min(radius, rect.width / 2, rect.height / 2)
        let c = r * 0.5522847498
        let path = PBezierPath()
        if roundTop {
            path.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
            path.line(to: CGPoint(x: rect.maxX - r, y: rect.minY))
            path.curve(
                to: CGPoint(x: rect.maxX, y: rect.minY + r),
                controlPoint1: CGPoint(x: rect.maxX - r + c, y: rect.minY),
                controlPoint2: CGPoint(x: rect.maxX, y: rect.minY + r - c)
            )
        } else {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        }
        path.line(to: CGPoint(x: rect.maxX, y: rect.maxY - (roundBottom ? r : 0)))
        if roundBottom {
            path.curve(
                to: CGPoint(x: rect.maxX - r, y: rect.maxY),
                controlPoint1: CGPoint(x: rect.maxX, y: rect.maxY - r + c),
                controlPoint2: CGPoint(x: rect.maxX - r + c, y: rect.maxY)
            )
            path.line(to: CGPoint(x: rect.minX + r, y: rect.maxY))
            path.curve(
                to: CGPoint(x: rect.minX, y: rect.maxY - r),
                controlPoint1: CGPoint(x: rect.minX + r - c, y: rect.maxY),
                controlPoint2: CGPoint(x: rect.minX, y: rect.maxY - r + c)
            )
        } else {
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        }
        path.line(to: CGPoint(x: rect.minX, y: rect.minY + (roundTop ? r : 0)))
        return path
    }

    /// The card is one visual run drawn a fragment at a time. Only the outside
    /// fragments draw horizontal borders; middle fragments are square bands so
    /// later fragments never paint over neighboring text.
    private func drawCodeCard(origin: CGPoint) {
        guard let container = textLayoutManager?.textContainer else { return }
        let width = container.size.width
        guard width > 24 else { return }
        let (first, last) = codeRunEdges()
        let radius: CGFloat = 8
        let padding = CodeHighlight.cardVerticalPadding
        let top: CGFloat = first ? 0.5 - padding : 0
        let bottom: CGFloat = last ? layoutFragmentFrame.height - 0.5 + padding : layoutFragmentFrame.height
        let rect = CGRect(
            x: origin.x + 2.5,
            y: top,
            width: width - 5,
            height: bottom - top
        )
        let fillPath = codeCardPath(rect: rect, radius: radius, roundTop: first, roundBottom: last)
        let strokePath = codeCardStrokePath(rect: rect, radius: radius, roundTop: first, roundBottom: last)
        CodeHighlight.cardBackground.setFill()
        fillPath.fill()
        CodeHighlight.cardBorder.setStroke()
        strokePath.lineWidth = 1
        strokePath.stroke()
        drawSelection()
    }

    /// The card fill lands on top of the selection the text view painted into
    /// the background, so the fragment repaints the covered part itself.
    private func drawSelection() {
        guard let selection = selectionProvider?(),
              selection.range.length > 0,
              let (_, elementStart) = storageContext()
        else { return }
        selection.color.setFill()
        for line in textLineFragments {
            let lineRange = NSRange(
                location: elementStart + line.characterRange.location,
                length: line.characterRange.length
            )
            let hit = NSIntersectionRange(lineRange, selection.range)
            guard hit.length > 0 else { continue }
            let start = line.locationForCharacter(at: hit.location - elementStart).x
            let end = line.locationForCharacter(at: NSMaxRange(hit) - elementStart).x
            guard end > start else { continue }
            let bounds = line.typographicBounds
            PBezierPath(rect: CGRect(
                x: bounds.minX + start,
                y: bounds.minY,
                width: end - start,
                height: bounds.height
            )).fill()
        }
    }

    /// The line box of an embed drawn by a hosted view, if this fragment is
    /// one.
    private var hostedEmbedRect: CGRect? {
        guard let paragraph = textElement as? NSTextParagraph else { return nil }
        let string = paragraph.attributedString
        guard string.length > 0, string.length <= 2,
              string.attribute(.attachment, at: 0, effectiveRange: nil) is EmbedAttachment,
              let line = textLineFragments.first
        else { return nil }
        return line.typographicBounds
    }

    override func draw(at point: CGPoint, in context: CGContext) {
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
        let contentLines = textLineFragments.filter { $0.characterRange.length > 0 }
        if drawsCodeCard {
            drawCodeCard(origin: origin)
        }
        if let block = decoratedBlock(attrs), block.type == "blockquote",
           let width = textLayoutManager?.textContainer?.size.width {
            let lineRect = contentLines.reduce(CGRect.null) { $0.union($1.typographicBounds) }
            if !lineRect.isNull {
                let edges = quoteRunEdges()
                MarkerDrawing.quoteBackground(
                    lineRect: lineRect,
                    origin: origin,
                    containerWidth: width,
                    first: edges.first,
                    last: edges.last
                )
            }
        }
        if isTypingQuoteBlockOnTrailingLine,
           let extraLine = trailingEmptyLine,
           let width = textLayoutManager?.textContainer?.size.width {
            MarkerDrawing.quoteBackground(
                lineRect: extraLine.typographicBounds,
                origin: origin,
                containerWidth: width
            )
        }
        super.draw(at: point, in: context)
        // super.draw is what builds the attachment's view provider, and an
        // imageless attachment draws TextKit's generic document icon in that
        // same pass — one frame before the view mounts. Wipe it; the loading
        // view is what should be seen there.
        if let embedRect = hostedEmbedRect {
            PColor.pOnTint.setFill()
            PBezierPath(rect: embedRect).fill()
        }
        if let block = decoratedBlock(attrs), block.type == "blockquote",
           let width = textLayoutManager?.textContainer?.size.width {
            let lineRect = contentLines.reduce(CGRect.null) { $0.union($1.typographicBounds) }
            if !lineRect.isNull {
                let edges = quoteRunEdges()
                MarkerDrawing.quoteAccent(
                    lineRect: lineRect,
                    origin: origin,
                    containerWidth: width,
                    first: edges.first,
                    last: edges.last
                )
            }
        }
        if isTypingQuoteBlockOnTrailingLine,
           let extraLine = trailingEmptyLine,
           let width = textLayoutManager?.textContainer?.size.width {
            MarkerDrawing.quoteAccent(
                lineRect: extraLine.typographicBounds,
                origin: origin,
                containerWidth: width
            )
        }
        if attrs?[.amChanged] != nil {
            let lineRect = textLineFragments.reduce(CGRect.null) { $0.union($1.typographicBounds) }
            if !lineRect.isNull {
                MarkerDrawing.changeBar(lineRect: lineRect, origin: origin)
            }
        }
        if let key = headingFoldKey,
           foldedHeadingsProvider?().contains(key) == true,
           let lineRect = contentLines.first?.typographicBounds {
            let font = attrs?[.font] as? PFont ?? PFont.systemFont(ofSize: RichText.bodySize)
            MarkerDrawing.foldChevron(lineRect: lineRect, origin: origin, font: font)
        }
        if let block = decoratedBlock(attrs), let attrs,
           block.type != "blockquote",
           let lineRect = contentLines.first?.typographicBounds {
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

        guard let extraLine = trailingEmptyLine,
              let typing = typingAttributesProvider?(),
              let block = decoratedBlock(typing),
              block.type != "blockquote"
        else { return }
        let lineRect = extraLine.typographicBounds
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
        guard location >= 0, location <= storage.length else { return nil }
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
        guard previous.location >= 0,
              previous.location < storage.length,
              let prevBox = storage.attribute(.amBlock, at: previous.location, effectiveRange: nil) as? BlockBox,
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
              range.location >= 0,
              range.location < storage.length,
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

/// Run-scoped tokenizing and card corners both depend on neighbouring
/// paragraphs, so an edit in or next to a code run redraws the whole run.
func invalidateCodeRun(
    around location: Int,
    textLayoutManager: NSTextLayoutManager,
    storage: NSTextStorage
) {
    guard storage.length > 0 else { return }
    let str = storage.string as NSString
    let anchor = min(max(location, 0), storage.length - 1)
    let paragraph = str.paragraphRange(for: NSRange(location: anchor, length: 0))

    var start = paragraph.location
    if start > 0 {
        start = str.paragraphRange(for: NSRange(location: start - 1, length: 0)).location
    }
    var end = NSMaxRange(paragraph)
    if end < storage.length {
        end = NSMaxRange(str.paragraphRange(for: NSRange(location: end, length: 0)))
    }
    while start > 0 {
        let previous = str.paragraphRange(for: NSRange(location: start - 1, length: 0))
        guard CodeHighlight.isCodeParagraph(previous, language: nil, in: storage) else { break }
        start = previous.location
    }
    while end < storage.length {
        let next = str.paragraphRange(for: NSRange(location: end, length: 0))
        guard CodeHighlight.isCodeParagraph(next, language: nil, in: storage) else { break }
        end = NSMaxRange(next)
    }

    var containsCode = false
    var cursor = start
    while cursor < end {
        let range = str.paragraphRange(for: NSRange(location: cursor, length: 0))
        if CodeHighlight.isCodeParagraph(range, language: nil, in: storage) {
            containsCode = true
            break
        }
        cursor = NSMaxRange(range)
    }
    guard containsCode,
          let contentManager = textLayoutManager.textContentManager,
          let textRange = contentManager.textRange(for: NSRange(location: start, length: end - start))
    else { return }
    textLayoutManager.invalidateLayout(for: textRange)
}

final class ListMarkerLayoutDelegate: NSObject, NSTextLayoutManagerDelegate {
    var typingAttributesProvider: (() -> [NSAttributedString.Key: Any]?)?
    var foldedHeadingsProvider: (() -> Set<HeadingFoldKey>)?
    var selectionProvider: (() -> (range: NSRange, color: PColor)?)?

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
        fragment.foldedHeadingsProvider = foldedHeadingsProvider
        fragment.selectionProvider = selectionProvider
        return fragment
    }
}
