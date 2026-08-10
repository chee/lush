#if os(macOS)
import AppKit

typealias PFont = NSFont
typealias PColor = NSColor
typealias PImage = NSImage
typealias PView = NSView
typealias PFontDescriptor = NSFontDescriptor
typealias PBezierPath = NSBezierPath
#else
import UIKit

typealias PFont = UIFont
typealias PColor = UIColor
typealias PImage = UIImage
typealias PView = UIView
typealias PFontDescriptor = UIFontDescriptor
typealias PBezierPath = UIBezierPath

extension UIBezierPath {
    func line(to point: CGPoint) { addLine(to: point) }
}
#endif

import SwiftUI

extension Image {
    init(pImage: PImage) {
        #if os(macOS)
        self.init(nsImage: pImage)
        #else
        self.init(uiImage: pImage)
        #endif
    }
}

enum Clipboard {
    static func copy(_ string: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #else
        UIPasteboard.general.string = string
        #endif
    }
}

enum ExternalBrowser {
    static func open(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }
}

extension PColor {
    convenience init(rgb: Int, alpha: CGFloat = 1) {
        let r = CGFloat((rgb >> 16) & 0xFF) / 255
        let g = CGFloat((rgb >> 8) & 0xFF) / 255
        let b = CGFloat(rgb & 0xFF) / 255
        #if os(macOS)
        self.init(srgbRed: r, green: g, blue: b, alpha: alpha)
        #else
        self.init(red: r, green: g, blue: b, alpha: alpha)
        #endif
    }

    static var pLabel: PColor {
        #if os(macOS)
        .labelColor
        #else
        .label
        #endif
    }

    static var pSecondaryLabel: PColor {
        #if os(macOS)
        .secondaryLabelColor
        #else
        .secondaryLabel
        #endif
    }

    /// The accent colour, and something that reads on top of it.
    static var pTint: PColor {
        #if os(macOS)
        PColor(named: NSColor.Name("AccentColor")) ?? .controlAccentColor
        #else
        PColor(named: "AccentColor") ?? .tintColor
        #endif
    }

    static var pOnTint: PColor {
        #if os(macOS)
        .textBackgroundColor
        #else
        .systemBackground
        #endif
    }

    static var pGroupedBackground: PColor {
        #if os(macOS)
        .windowBackgroundColor
        #else
        .systemGroupedBackground
        #endif
    }
}

extension PImage {
    static func symbol(_ name: String) -> PImage? {
        #if os(macOS)
        PImage(systemSymbolName: name, accessibilityDescription: nil)
        #else
        PImage(systemName: name)
        #endif
    }

    static func draw(size: CGSize, _ body: @escaping (CGContext) -> Void) -> PImage {
        #if os(macOS)
        NSImage(size: size, flipped: true) { _ in
            if let ctx = NSGraphicsContext.current?.cgContext {
                body(ctx)
            }
            return true
        }
        #else
        UIGraphicsImageRenderer(size: size).image { ctx in
            body(ctx.cgContext)
        }
        #endif
    }

    /// Video poster frame with a centered play badge.
    static func playBadged(_ base: PImage) -> PImage {
        let size = base.size
        return draw(size: size) { ctx in
            base.draw(in: CGRect(origin: .zero, size: size))
            let diameter = min(size.width, size.height) * 0.28
            let circle = CGRect(
                x: (size.width - diameter) / 2,
                y: (size.height - diameter) / 2,
                width: diameter,
                height: diameter
            )
            ctx.setFillColor(PColor.black.withAlphaComponent(0.55).cgColor)
            ctx.fillEllipse(in: circle)
            let side = diameter * 0.42
            let cx = circle.midX + side * 0.1
            let cy = circle.midY
            ctx.setFillColor(PColor.white.cgColor)
            ctx.move(to: CGPoint(x: cx - side / 2, y: cy - side / 2))
            ctx.addLine(to: CGPoint(x: cx - side / 2, y: cy + side / 2))
            ctx.addLine(to: CGPoint(x: cx + side / 2, y: cy))
            ctx.closePath()
            ctx.fillPath()
        }
    }
}

extension PFont {
    /// `familyName` is optional on AppKit and not on UIKit.
    var pFamilyName: String? {
        #if os(macOS)
        familyName
        #else
        familyName
        #endif
    }

    var hasBoldTrait: Bool {
        #if os(macOS)
        fontDescriptor.symbolicTraits.contains(.bold)
        #else
        fontDescriptor.symbolicTraits.contains(.traitBold)
        #endif
    }

    var hasItalicTrait: Bool {
        #if os(macOS)
        fontDescriptor.symbolicTraits.contains(.italic)
        #else
        fontDescriptor.symbolicTraits.contains(.traitItalic)
        #endif
    }

    var hasMonoSpaceTrait: Bool {
        #if os(macOS)
        fontDescriptor.symbolicTraits.contains(.monoSpace)
        #else
        fontDescriptor.symbolicTraits.contains(.traitMonoSpace)
        #endif
    }

    func addingTraits(bold: Bool = false, italic: Bool = false) -> PFont {
        #if os(macOS)
        var traits = fontDescriptor.symbolicTraits
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        let descriptor = fontDescriptor.withSymbolicTraits(traits)
        return PFont(descriptor: descriptor, size: pointSize) ?? self
        #else
        var traits = fontDescriptor.symbolicTraits
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        guard let descriptor = fontDescriptor.withSymbolicTraits(traits) else {
            return self
        }
        return PFont(descriptor: descriptor, size: pointSize)
        #endif
    }
}

extension PFont.Weight {
    var swiftUI: Font.Weight {
        switch self {
        case .ultraLight: .ultraLight
        case .thin: .thin
        case .light: .light
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        default: .regular
        }
    }
}

extension Font {
    init(pFont: PFont) {
        #if os(macOS)
        self.init(pFont as CTFont)
        #else
        self.init(pFont)
        #endif
    }
}

extension View {
    /// `.onExitCommand` exists only on macOS.
    func onEscape(perform action: @escaping () -> Void) -> some View {
        #if os(macOS)
        return onExitCommand(perform: action)
        #else
        return self
        #endif
    }
}

import SwiftUI
