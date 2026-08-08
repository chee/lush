import SwiftUI

enum FontRole {
    static let all: [(key: String, label: String)] = [
        ("ui", "Interface"),
        ("sans", "Sans"),
        ("serif", "Serif"),
        ("mono", "Mono"),
        ("hand", "Hand"),
    ]

    static func family(_ role: String) -> String {
        role == "ui" ? InterfaceFont.family : EditorSettings.family(for: role)
    }

    static func setFamily(_ family: String, role: String) {
        guard role == "ui" else {
            EditorSettings.setFamily(family, for: role)
            return
        }
        UserDefaults.standard.set(family, forKey: InterfaceFont.familyKey)
        NotificationCenter.default.post(name: EditorSettings.changed, object: nil)
    }

    static func displayName(_ family: String) -> String {
        family == EditorSettings.systemFontFamily ? "System Default" : family
    }

    static func size(_ role: String) -> CGFloat {
        role == "ui" ? InterfaceFont.size(.body) : EditorSettings.bodySize
    }

    static func font(
        _ role: String,
        family: String? = nil,
        adjustment: FontAdjustment? = nil,
        size: CGFloat? = nil,
        weight: PFont.Weight = .regular
    ) -> Font {
        let family = family ?? self.family(role)
        return Font(pFont: EditorSettings.font(
            role: role,
            family: family,
            adjustment: adjustment ?? EditorSettings.adjustment(family: family, role: role),
            ofSize: size ?? self.size(role),
            weight: weight
        ))
    }
}

private struct RoleSelection: Identifiable {
    let id: String
    let label: String
}

struct FontSettingsSections: View {
    @State private var version = 0
    @State private var editing: RoleSelection?

    var body: some View {
        Group {
            Section("Fonts") {
                ForEach(FontRole.all, id: \.key) { role in
                    Button {
                        editing = RoleSelection(id: role.key, label: role.label)
                    } label: {
                        HStack {
                            Text(role.label)
                            Spacer()
                            Text(FontRole.displayName(FontRole.family(role.key)))
                                .font(FontRole.font(role.key))
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .uiFont(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
            Section("Specimen") {
                FontSpecimen()
            }
        }
        .id(version)
        .onReceive(NotificationCenter.default.publisher(for: EditorSettings.changed)) { _ in
            version += 1
        }
        .sheet(item: $editing) { role in
            FontChooser(role: role.id, label: role.label)
        }
    }
}

/// Every role in one block, because pairing is only judgeable together.
struct FontSpecimen: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Hamburgefonstiv")
                .font(FontRole.font("sans", size: EditorSettings.bodySize + 10, weight: .bold))
            Text("Sans carries the body text, ")
                .font(FontRole.font("sans"))
            + Text("bold sits inside it")
                .font(FontRole.font("sans", weight: .bold))
            + Text(", and ")
                .font(FontRole.font("sans"))
            + Text("italic leans")
                .font(FontRole.font("sans").italic())
            + Text(".")
                .font(FontRole.font("sans"))

            Text("Serif runs alongside at the same nominal size — 0123456789.")
                .font(FontRole.font("serif"))

            Text("Mono for ")
                .font(FontRole.font("sans"))
            + Text("let x = 1")
                .font(FontRole.font("mono", size: EditorSettings.bodySize - 1))
            + Text(" inline.")
                .font(FontRole.font("sans"))

            Text("Hand writes a line at the end.")
                .font(FontRole.font("hand"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }
}

struct FontChooser: View {
    let role: String
    let label: String
    @Environment(\.dismiss) private var dismiss
    @State private var family: String
    @State private var adjustment: FontAdjustment
    @State private var advanced = false
    @State private var search = ""

    init(role: String, label: String) {
        self.role = role
        self.label = label
        let family = FontRole.family(role)
        _family = State(initialValue: family)
        _adjustment = State(initialValue: EditorSettings.adjustment(family: family, role: role))
    }

    private var families: [String] {
        let all = EditorSettings.availableFontFamilies
        guard !search.isEmpty else { return all }
        return all.filter { $0.localizedCaseInsensitiveContains(search) }
    }

    private var previewSize: CGFloat { FontRole.size(role) + 6 }

    private var scalePercent: String {
        let percent: Int = Int((adjustment.scale * 100).rounded())
        return "\(percent)%"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    preview
                }
                Section("Size") {
                    HStack {
                        Slider(value: $adjustment.scale, in: 0.7...1.4, step: 0.01)
                        Text(scalePercent)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Button("Reset") { adjustment.scale = 1 }
                            .disabled(adjustment.scale == 1)
                    }
                }
                Section(isExpanded: $advanced) {
                    weightPicker("Normal", selection: $adjustment.regularWeight)
                    weightPicker("Bold", selection: $adjustment.boldWeight)
                    Text("Automatic uses the family's own regular and bold faces. A variable family can take any weight; others snap to the nearest face.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Weights")
                }
                Section("Family") {
                    familyRow(EditorSettings.systemFontFamily)
                    ForEach(families, id: \.self) { name in
                        familyRow(name)
                    }
                }
            }
            .searchable(text: $search, prompt: "Filter families")
            .navigationTitle("\(label) Font")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(width: 520, height: 640)
        #endif
        .onChange(of: family) {
            FontRole.setFamily(family, role: role)
            adjustment = EditorSettings.adjustment(family: family, role: role)
        }
        .onChange(of: adjustment) {
            EditorSettings.setAdjustment(adjustment, family: family, role: role)
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hamburgefonstiv 0123")
                .font(font(size: previewSize))
            Text("Regular ")
                .font(font())
            + Text("Bold ")
                .font(font(weight: .bold))
            + Text("Italic")
                .font(font().italic())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    private func font(size: CGFloat? = nil, weight: PFont.Weight = .regular) -> Font {
        FontRole.font(role, family: family, adjustment: adjustment, size: size, weight: weight)
    }

    private func familyRow(_ name: String) -> some View {
        Button {
            family = name
        } label: {
            HStack {
                Text(FontRole.displayName(name))
                    .font(FontRole.font(
                        role,
                        family: name,
                        adjustment: EditorSettings.adjustment(family: name, role: role)
                    ))
                Spacer()
                if name == family {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func weightPicker(_ title: String, selection: Binding<Double?>) -> some View {
        Picker(title, selection: selection) {
            Text("Automatic").tag(Double?.none)
            ForEach(FontAdjustment.weights, id: \.value) { weight in
                Text(weight.label).tag(Double?.some(weight.value))
            }
        }
    }
}
