import SwiftUI

/// Picks the provider and model for one run, without changing the task's
/// configured default. `selection` nil means "whatever the task is set to".
struct ModelChoiceMenu: View {
    let operation: LocalModelOperation
    @Binding var selection: ModelChoice?

    @State private var choices: [ModelChoice] = []

    var body: some View {
        Menu {
            Button {
                selection = nil
            } label: {
                Label(
                    "Task Default (\(LocalModelSettings.choice(for: operation).detailedLabel))",
                    systemImage: selection == nil ? "checkmark" : ""
                )
            }
            Divider()
            ForEach(groupedChoices, id: \.backend) { group in
                Menu(group.backend.label) {
                    ForEach(group.choices) { choice in
                        Button {
                            selection = choice
                        } label: {
                            Label(
                                choice.model.isEmpty ? "Default" : choice.model,
                                systemImage: selection == choice ? "checkmark" : ""
                            )
                        }
                    }
                }
            }
        } label: {
            Label(
                selection?.label ?? LocalModelSettings.choice(for: operation).label,
                systemImage: "sparkles"
            )
            .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .task {
            choices = LocalModelSettings.availableChoices()
            // ollama names no default model, so it has nothing to offer until
            // its own list of pulled models is read
            guard LocalModelSettings.isConnected(.ollama),
                  let pulled = try? await OllamaModelCatalog.fetch()
            else { return }
            var seen = Set(choices.map(\.id))
            choices += pulled
                .map { ModelChoice(backend: .ollama, model: $0.name) }
                .filter { seen.insert($0.id).inserted }
        }
    }

    private var groupedChoices: [(backend: LocalModelBackend, choices: [ModelChoice])] {
        LocalModelBackend.allCases.compactMap { backend in
            let matching = choices.filter { $0.backend == backend }
            return matching.isEmpty ? nil : (backend, matching)
        }
    }
}
