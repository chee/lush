import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum InterfaceFont {
    static let familyKey = "uiFontFamily"

    static var family: String {
        UserDefaults.standard.string(forKey: familyKey) ?? EditorSettings.systemFontFamily
    }

    static func font(_ style: Font.TextStyle, family: String, weight: Font.Weight?) -> Font {
        let adjustment = EditorSettings.adjustment(family: family, role: "ui")
        let size = size(style) * adjustment.scale
        var font: Font
        if family == EditorSettings.systemFontFamily {
            font = adjustment.scale == 1
                ? .system(style)
                : .system(size: scaled(size, relativeTo: style))
        } else {
            EditorSettings.registerBundledFonts()
            font = .custom(family, size: size, relativeTo: style)
        }
        if let weight {
            font = font.weight(weight)
        } else if let regular = adjustment.regularWeight {
            font = font.weight(EditorSettings.platformWeight(regular).swiftUI)
        }
        return font
    }

    static func size(_ style: Font.TextStyle) -> CGFloat {
        #if os(macOS)
        switch style {
        case .largeTitle: 26
        case .title: 22
        case .title2: 17
        case .title3: 15
        case .headline: 13
        case .body: 13
        case .callout: 12
        case .subheadline: 11
        case .footnote: 10
        case .caption: 10
        case .caption2: 10
        default: 13
        }
        #else
        switch style {
        case .largeTitle: 34
        case .title: 28
        case .title2: 22
        case .title3: 20
        case .headline: 17
        case .body: 17
        case .callout: 16
        case .subheadline: 15
        case .footnote: 13
        case .caption: 12
        case .caption2: 11
        default: 17
        }
        #endif
    }

    static func scaled(_ size: CGFloat, relativeTo style: Font.TextStyle) -> CGFloat {
        #if os(iOS)
        UIFontMetrics(forTextStyle: uiTextStyle(style)).scaledValue(for: size)
        #else
        size
        #endif
    }

    #if os(iOS)
    private static func uiTextStyle(_ style: Font.TextStyle) -> UIFont.TextStyle {
        switch style {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .callout: .callout
        case .subheadline: .subheadline
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        default: .body
        }
    }
    #endif

    static func platformFont(ofSize size: CGFloat, weight: PFont.Weight, family: String) -> PFont {
        EditorSettings.font(
            role: "ui",
            family: family,
            adjustment: EditorSettings.adjustment(family: family, role: "ui"),
            ofSize: size,
            weight: weight
        )
    }

    static func applyNavigationBarAppearance(family: String) {
        #if os(iOS)
        let large = UIFontMetrics(forTextStyle: .largeTitle).scaledFont(
            for: platformFont(ofSize: 34, weight: .medium, family: family)
        )
        let inline = UIFontMetrics(forTextStyle: .headline).scaledFont(
            for: platformFont(ofSize: 17, weight: .regular, family: family)
        )
        let standard = UINavigationBarAppearance()
        standard.configureWithDefaultBackground()
        standard.largeTitleTextAttributes = [.font: large]
        standard.titleTextAttributes = [.font: inline]
        let scrollEdge = UINavigationBarAppearance()
        scrollEdge.configureWithTransparentBackground()
        scrollEdge.largeTitleTextAttributes = [.font: large]
        scrollEdge.titleTextAttributes = [.font: inline]
        UINavigationBar.appearance().standardAppearance = standard
        UINavigationBar.appearance().compactAppearance = standard
        UINavigationBar.appearance().scrollEdgeAppearance = scrollEdge
        #endif
    }
}

private struct InterfaceFontFamilyKey: EnvironmentKey {
    static var defaultValue: String { InterfaceFont.family }
}

extension EnvironmentValues {
    var interfaceFontFamily: String {
        get { self[InterfaceFontFamilyKey.self] }
        set { self[InterfaceFontFamilyKey.self] = newValue }
    }
}

private struct InterfaceFontModifier: ViewModifier {
    @Environment(\.interfaceFontFamily) private var family
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let style: Font.TextStyle
    let weight: Font.Weight?

    func body(content: Content) -> some View {
        _ = dynamicTypeSize
        return content.font(InterfaceFont.font(style, family: family, weight: weight))
    }
}

private struct InterfaceFontRoot: ViewModifier {
    @AppStorage(InterfaceFont.familyKey) private var family = EditorSettings.systemFontFamily

    func body(content: Content) -> some View {
        content
            .environment(\.interfaceFontFamily, family)
            .font(InterfaceFont.font(.body, family: family, weight: nil))
            .tint(Color("AccentColor"))
            .onChange(of: family, initial: true) {
                InterfaceFont.applyNavigationBarAppearance(family: family)
            }
    }
}

extension View {
    func uiFont(_ style: Font.TextStyle, weight: Font.Weight? = nil) -> some View {
        modifier(InterfaceFontModifier(style: style, weight: weight))
    }

    func interfaceFont() -> some View {
        modifier(InterfaceFontRoot())
    }
}
