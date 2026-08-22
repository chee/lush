#if os(macOS)
import SwiftUI

struct FormatMenuButton: View {
    let controller: EditorController
    @State private var showing = false

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            Text("Aa")
                .font(glyphFont)
                .baselineOffset(baselineShift)
                .underline(controller.underlineActive)
                .strikethrough(controller.strikethroughActive)
                .foregroundStyle(marksActive ? Color.accentColor : Color.primary)
                .frame(minWidth: 22)
        }
        .help("Format")
        .accessibilityLabel("Format")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            FormatPopover(controller: controller)
        }
    }

    private var marksActive: Bool {
        controller.strongActive || controller.emActive || controller.underlineActive
            || controller.strikethroughActive || controller.codeActive
            || controller.superscriptActive || controller.subscriptActive
            || controller.fontRoleActive != nil
    }

    private var baselineShift: CGFloat {
        if controller.superscriptActive { return 3 }
        if controller.subscriptActive { return -2 }
        return 0
    }

    private var glyphFont: Font {
        let size: CGFloat = baselineShift == 0 ? 13 : 10
        var font: PFont
        if controller.codeActive {
            font = EditorSettings.font(family: "mono", ofSize: size)
        } else if let role = controller.fontRoleActive {
            font = EditorSettings.font(family: role, ofSize: size)
        } else {
            font = .systemFont(ofSize: size)
        }
        if controller.strongActive || controller.emActive {
            font = EditorSettings.styled(
                font,
                bold: controller.strongActive,
                italic: controller.emActive
            )
        }
        return Font(font)
    }
}

struct FormatPopover: View {
    let controller: EditorController

    private static let groups: [[String]] = [
        ["heading1", "heading2", "heading3", "paragraph", "code-block"],
        ["unordered-list-item", "ordered-list-item", "todo-list-item"],
        ["blockquote"],
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            marksRow
            fontRow
            highlightRow
            Divider()
            ForEach(Self.groups.indices, id: \.self) { index in
                if index > 0 { Divider() }
                ForEach(Self.groups[index], id: \.self) { key in
                    FormatStyleRow(
                        key: key,
                        active: controller.currentStyleKey == key,
                        action: {
                            controller.applyStyle(controller.currentStyleKey == key ? "paragraph" : key)
                        }
                    )
                }
            }
            Divider()
            indentRow
            if controller.isCodeBlockActive {
                Divider()
                languageRow
            }
        }
        .padding(10)
        .frame(width: 236)
    }

    private var marksRow: some View {
        HStack(spacing: 0) {
            markButton("Bold", active: controller.strongActive, action: controller.toggleStrong) {
                Text("B").font(.system(size: 14, weight: .bold))
            }
            markButton("Italic", active: controller.emActive, action: controller.toggleEm) {
                Text("I").font(.system(size: 14).italic())
            }
            markButton("Underline", active: controller.underlineActive, action: controller.toggleUnderline) {
                Text("U").font(.system(size: 14)).underline()
            }
            markButton("Strikethrough", active: controller.strikethroughActive, action: controller.toggleStrikethrough) {
                Text("S").font(.system(size: 14)).strikethrough()
            }
            markButton("Link", active: controller.linkActive != nil, action: controller.editLink) {
                Image(systemName: "link").font(.system(size: 12))
            }
            Divider().frame(height: 18)
            markButton("Superscript", active: controller.superscriptActive, action: controller.toggleSuperscript) {
                Image(systemName: "textformat.superscript").font(.system(size: 12))
            }
            markButton("Subscript", active: controller.subscriptActive, action: controller.toggleSubscript) {
                Image(systemName: "textformat.subscript").font(.system(size: 12))
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.06))
        .clipShape(Capsule())
    }

    private var fontRow: some View {
        HStack(spacing: 6) {
            ForEach(RichText.fontRoles, id: \.key) { role in
                fontButton(
                    label: role.label,
                    family: role.key,
                    active: controller.fontRoleActive == role.key
                ) {
                    controller.applyFontRole(controller.fontRoleActive == role.key ? nil : role.key)
                }
            }
            fontButton(label: "Code", family: "mono", active: controller.codeActive) {
                controller.toggleCode()
            }
            Spacer()
        }
    }

    private func fontButton(
        label: String,
        family: String,
        active: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(Font(EditorSettings.font(family: family, ofSize: 12)))
                .foregroundStyle(active ? Color.accentColor : Color.primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(active ? Color.accentColor.opacity(0.16) : Color.clear)
                .clipShape(Capsule())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private var highlightRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "highlighter")
                .font(.system(size: 12))
                .foregroundStyle(controller.highlightActive != nil ? Color.accentColor : Color.secondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            ForEach(Highlight.names, id: \.self) { name in
                Button {
                    controller.applyHighlight(controller.highlightActive == name ? nil : name)
                } label: {
                    Circle()
                        .fill(Color(nsColor: Highlight.background(name)))
                        .overlay {
                            Circle().strokeBorder(
                                controller.highlightActive == name ? Color.accentColor : Color.primary.opacity(0.12),
                                lineWidth: controller.highlightActive == name ? 2 : 1
                            )
                        }
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help(name.capitalized)
                .accessibilityLabel("\(name.capitalized) Highlight")
                .accessibilityAddTraits(controller.highlightActive == name ? .isSelected : [])
            }
            Button {
                controller.applyHighlight(nil)
            } label: {
                Image(systemName: "slash.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.secondary)
            }
            .buttonStyle(.plain)
            .help("No Highlight")
            .accessibilityLabel("No Highlight")
        }
    }

    private var indentRow: some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                markButton("Decrease Indent", active: false, action: controller.outdentBlock) {
                    Image(systemName: "decrease.indent").font(.system(size: 12))
                }
                markButton("Increase Indent", active: false, action: controller.indentBlock) {
                    Image(systemName: "increase.indent").font(.system(size: 12))
                }
            }
            .padding(2)
            .background(Color.primary.opacity(0.06))
            .clipShape(Capsule())
            Spacer()
        }
    }

    private var languageRow: some View {
        HStack {
            Text("Language").foregroundStyle(Color.secondary)
            Spacer()
            Picker("", selection: Binding(
                get: { CodeLanguage.named(controller.currentCodeLanguage).id },
                set: { controller.applyCodeLanguage(CodeLanguage.named($0)) }
            )) {
                ForEach(CodeLanguage.all) { language in
                    Text(language.name).tag(language.id)
                }
            }
            .labelsHidden()
            .frame(width: 130)
        }
        .font(.system(size: 12))
    }

    private func markButton(
        _ name: String,
        active: Bool,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> some View
    ) -> some View {
        Button(action: action) {
            label()
                .foregroundStyle(active ? Color.accentColor : Color.primary)
                .frame(width: 26, height: 24)
                .background(active ? Color.accentColor.opacity(0.16) : Color.clear)
                .clipShape(Capsule())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

private struct FormatStyleRow: View {
    let key: String
    let active: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .opacity(active ? 1 : 0)
                    .frame(width: 12)
                if let marker {
                    Text(marker)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.secondary)
                }
                Text(label)
                    .font(sample)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(hovering ? Color.primary.opacity(0.07) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private var label: String {
        EditorController.styles.first { $0.key == key }?.label ?? key
    }

    private var marker: String? {
        switch key {
        case "unordered-list-item": "•"
        case "ordered-list-item": "1."
        case "todo-list-item": "☐"
        case "blockquote": "|"
        default: nil
        }
    }

    private var sample: Font {
        switch key {
        case "heading1": .system(size: 19, weight: .bold)
        case "heading2": .system(size: 15, weight: .bold)
        case "heading3": .system(size: 13, weight: .semibold)
        case "serif": Font(EditorSettings.font(family: "serif", ofSize: 13))
        case "hand": Font(EditorSettings.font(family: "hand", ofSize: 15))
        case "code-block": Font(EditorSettings.font(family: "mono", ofSize: 12))
        default: .system(size: 13)
        }
    }
}
#endif
