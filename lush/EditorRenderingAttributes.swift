#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Display-only paint for the main editor, composed in one validator:
/// syntax colors, then find-match backgrounds. Nothing here touches the
/// storage or the automerge round-trip.
@MainActor
final class EditorRenderingAttributes {
    var findMatches: [NSRange] = []
    var currentFindMatch: NSRange?
    var globalMatches: [NSRange] = []

    /// The accent is a dynamic colour; asking it for an alpha variant without
    /// first resolving it into a real colour space can paint nothing at all.
    static func tint(_ alpha: CGFloat) -> PColor {
        #if os(macOS)
        let resolved = PColor.pTint.usingColorSpace(.sRGB) ?? PColor.pTint
        #else
        let resolved = PColor.pTint
        #endif
        return resolved.withAlphaComponent(alpha)
    }

    private static func srgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat) -> PColor {
        #if os(macOS)
        PColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
        #else
        PColor(red: red, green: green, blue: blue, alpha: alpha)
        #endif
    }

    /// #fe8, the find highlight. Only the match she is on gets it, solid with
    /// #333 text so it reads the same in either appearance; the rest sit
    /// behind a neutral grey wash and keep their own colour.
    static let currentMatchColor = srgb(1, 0.933, 0.533, 1)

    static let currentMatchTextColor = srgb(0.2, 0.2, 0.2, 1)

    static let matchColor = srgb(0.5, 0.5, 0.5, 0.4)

    static let globalMatchColor = srgb(0.5, 0.5, 0.5, 0.25)

    /// What the layout fragment paints behind the text, back to front.
    var highlights: [(range: NSRange, color: PColor)] {
        var out = globalMatches.map { (range: $0, color: Self.globalMatchColor) }
        out += findMatches.map { (range: $0, color: Self.matchColor) }
        if let currentFindMatch {
            out.append((range: currentFindMatch, color: Self.currentMatchColor))
        }
        return out
    }

    var validator: (NSTextLayoutManager, NSTextLayoutFragment) -> Void {
        { [weak self] textLayoutManager, fragment in
            MainActor.assumeIsolated {
                self?.apply(textLayoutManager, fragment)
            }
        }
    }

    private func apply(_ textLayoutManager: NSTextLayoutManager, _ fragment: NSTextLayoutFragment) {
        let fragmentRange = Self.characterRange(of: fragment, in: textLayoutManager)
        CodeHighlight.applyRenderingAttributes(textLayoutManager, fragment)
        applyMatches(textLayoutManager, fragment, fragmentRange: fragmentRange)
    }

    private static func characterRange(of fragment: NSTextLayoutFragment, in textLayoutManager: NSTextLayoutManager) -> NSRange? {
        guard let contentStorage = textLayoutManager.textContentManager as? NSTextContentStorage,
              let elementRange = fragment.textElement?.elementRange
        else { return nil }
        let start = contentStorage.offset(from: contentStorage.documentRange.location, to: elementRange.location)
        let end = contentStorage.offset(from: contentStorage.documentRange.location, to: elementRange.endLocation)
        guard start >= 0, end > start else { return nil }
        return NSRange(location: start, length: end - start)
    }

    private func applyMatches(_ textLayoutManager: NSTextLayoutManager, _ fragment: NSTextLayoutFragment, fragmentRange: NSRange?) {
        guard !findMatches.isEmpty || !globalMatches.isEmpty,
              let fragmentRange,
              let contentStorage = textLayoutManager.textContentManager as? NSTextContentStorage
        else { return }

        // Backgrounds are drawn by the layout fragment (see `highlights`);
        // only the text colour goes through rendering attributes.
        guard let current = currentFindMatch else { return }
        let clipped = NSIntersectionRange(current, fragmentRange)
        guard clipped.length > 0, let textRange = contentStorage.textRange(for: clipped) else { return }
        textLayoutManager.addRenderingAttribute(
            .foregroundColor,
            value: Self.currentMatchTextColor,
            for: textRange
        )
    }
}
