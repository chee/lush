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
    var focusDimEnabled = false
    var focusParagraph: NSRange?

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

    static var matchColor: PColor { tint(0.3) }

    static var currentMatchColor: PColor { tint(0.65) }

    static var globalMatchColor: PColor { tint(0.18) }

    var validator: (NSTextLayoutManager, NSTextLayoutFragment) -> Void {
        { [weak self] textLayoutManager, fragment in
            MainActor.assumeIsolated {
                self?.apply(textLayoutManager, fragment)
            }
        }
    }

    private func apply(_ textLayoutManager: NSTextLayoutManager, _ fragment: NSTextLayoutFragment) {
        let fragmentRange = Self.characterRange(of: fragment, in: textLayoutManager)
        var dimmed = false
        if focusDimEnabled, let focus = focusParagraph, let fragmentRange {
            dimmed = NSIntersectionRange(fragmentRange, focus).length == 0
        }
        if dimmed, let fragmentRange,
           let contentStorage = textLayoutManager.textContentManager as? NSTextContentStorage,
           let textRange = contentStorage.textRange(for: fragmentRange) {
            textLayoutManager.setRenderingAttributes(
                [.foregroundColor: PColor.pSecondaryLabel.withAlphaComponent(0.55)],
                for: textRange
            )
        } else {
            CodeHighlight.applyRenderingAttributes(textLayoutManager, fragment)
        }
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

        func paint(_ matches: [NSRange], _ color: PColor) {
            for match in matches {
                let clipped = NSIntersectionRange(match, fragmentRange)
                guard clipped.length > 0,
                      let textRange = contentStorage.textRange(for: clipped)
                else { continue }
                textLayoutManager.addRenderingAttribute(.backgroundColor, value: color, for: textRange)
            }
        }

        paint(globalMatches, Self.globalMatchColor)
        paint(findMatches, Self.matchColor)
        if let current = currentFindMatch {
            paint([current], Self.currentMatchColor)
        }
    }
}
