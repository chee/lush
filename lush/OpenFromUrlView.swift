#if os(macOS)
import SwiftUI

struct OpenFromUrlView: View {
    let open: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""

    private var extracted: ExtractedAutomergeUrl? {
        AutomergeUrlExtraction.extract(from: input)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Open from URL")
                .font(.headline)
            TextField("Paste anything containing an automerge URL", text: $input)
                .textFieldStyle(.roundedBorder)
                .onSubmit(openExtracted)
            if let extracted {
                Text(extracted.display)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                if !extracted.heads.isEmpty {
                    Text("Opens the latest version; the heads above are shown for reference.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if !input.isEmpty {
                Text("No automerge URL found")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Open", action: openExtracted)
                    .keyboardShortcut(.defaultAction)
                    .disabled(extracted == nil)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func openExtracted() {
        guard let extracted else { return }
        dismiss()
        open(extracted.url)
    }
}
#endif
