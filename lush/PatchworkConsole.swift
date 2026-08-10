import SwiftUI

/// A JavaScript console for a patchwork embed. The script body runs in the
/// embed's page with `repo`, `handle`, `doc`, and `url` in scope; whatever
/// it returns is shown as JSON.
struct PatchworkConsole: View {
    let target: PatchworkScripting.Target
    var docUrl: String? = nil
    var onDone: (() -> Void)? = nil

    private static let sourceKey = "patchworkConsoleSource"

    @State private var source = UserDefaults.standard.string(forKey: sourceKey) ?? "return Object.keys(doc ?? {})"
    @State private var output = ""
    @State private var failed = false
    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("JavaScript")
                    .uiFont(.headline)
                Text("repo, handle, doc, url, Patchwork")
                    .uiFont(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if running {
                    ProgressView().controlSize(.small)
                }
                Button("Run", action: run)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(running || source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let onDone {
                    Button("Done", action: onDone)
                }
            }
            TextEditor(text: $source)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            ScrollView {
                Text(output)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(failed ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }
            .frame(minHeight: 100)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
        }
        .padding(12)
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 380)
        #endif
        .onChange(of: source) { _, value in
            UserDefaults.standard.set(value, forKey: Self.sourceKey)
        }
    }

    private func run() {
        running = true
        Task {
            do {
                let result = try await PatchworkScripting.shared.evaluate(
                    source,
                    docUrl: docUrl,
                    in: target
                )
                output = Self.pretty(result)
                failed = false
            } catch {
                output = error.localizedDescription
                failed = true
            }
            running = false
        }
    }

    static func pretty(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let formatted = try? JSONSerialization.data(
                  withJSONObject: value,
                  options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]
              )
        else { return json }
        return String(decoding: formatted, as: UTF8.self)
    }
}
