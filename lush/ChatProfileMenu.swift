import SwiftUI

/// Picks how the chat runs. The first entry follows whichever model is
/// selected, which is what most people want and what a new model should get.
struct ChatProfileMenu: View {
    let operation: LocalModelOperation
    let choice: ModelChoice

    @State private var selection: String?
    @State private var suggested: ChatProfile = .assistant

    var body: some View {
        Menu {
            Button {
                select(nil)
            } label: {
                Label(
                    "Suggested (\(suggested.name))",
                    systemImage: selection == nil ? "checkmark" : ""
                )
            }
            Divider()
            ForEach(ChatProfile.all) { profile in
                Button {
                    select(profile.id)
                } label: {
                    Label(
                        profile.name,
                        systemImage: selection == profile.id ? "checkmark" : ""
                    )
                }
                .help(profile.summary)
            }
        } label: {
            Label(
                ChatProfile.named(selection)?.name ?? suggested.name,
                systemImage: "slider.horizontal.3"
            )
            .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: 130, alignment: .leading)
        .task(id: choice) {
            selection = ChatProfileSettings.selection(for: operation)
            suggested = await ChatProfile.suggested(for: choice)
        }
    }

    private func select(_ id: String?) {
        selection = id
        ChatProfileSettings.setSelection(id, for: operation)
    }
}
