import SwiftUI
import Accessibility

/// Shows `NotesModel.status` — the channel every "Couldn't …" lands in — as a
/// transient notice. Errors stay up longer and carry a dismiss affordance;
/// progress messages clear themselves when the model clears the status.
struct StatusNoticeModifier: ViewModifier {
    @Environment(NotesModel.self) private var model
    @State private var message: String?
    @State private var isError = false
    @State private var hideTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: alignment) {
                if let message {
                    StatusNoticeCard(message: message, isError: isError) { hide() }
                        .padding(12)
                        .transition(.move(edge: edge).combined(with: .opacity))
                }
            }
            .onChange(of: model.status) { _, status in
                hideTask?.cancel()
                let trimmed = status.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    hide()
                    return
                }
                isError = Self.looksLikeError(trimmed)
                withAnimation(.snappy) { message = trimmed }
                AccessibilityNotification.Announcement(trimmed).post()
                let lifetime: Duration = .seconds(isError ? 12 : 5)
                hideTask = Task {
                    try? await Task.sleep(for: lifetime)
                    guard !Task.isCancelled else { return }
                    hide()
                }
            }
    }

    private func hide() {
        hideTask?.cancel()
        withAnimation(.snappy) { message = nil }
    }

    private var alignment: Alignment {
        #if os(macOS)
        .bottom
        #else
        .top
        #endif
    }

    private var edge: Edge {
        #if os(macOS)
        .bottom
        #else
        .top
        #endif
    }

    private static func looksLikeError(_ status: String) -> Bool {
        status.hasPrefix("Couldn't")
            || status.hasPrefix("Failed")
            || status.hasPrefix("Import incomplete")
    }
}

private struct StatusNoticeCard: View {
    let message: String
    let isError: Bool
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if isError {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
            }
            Text(message)
                .uiFont(.callout)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            if isError {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .frame(maxWidth: 420)
        .contentShape(Rectangle())
        .onTapGesture { dismiss() }
        .accessibilityElement(children: .combine)
        .accessibilityAction { dismiss() }
    }
}

extension View {
    func statusNotice() -> some View {
        modifier(StatusNoticeModifier())
    }
}
