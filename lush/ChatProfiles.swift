import Foundation

/// How much of the tool catalog a profile lets the model see. `asked` is the
/// middle setting: reading is always available, writing only when the person's
/// message was a request for a change.
enum ChatToolAccess: String, Codable {
    case none
    case asked
    case full
}

/// A way of running the chat: how much it is allowed to do, how long it may
/// think about it, and a line of instruction on top of the task's own system
/// prompt. A three-billion-parameter model and a frontier one want different
/// answers to all three, and the model cannot be asked to pick.
struct ChatProfile: Identifiable, Hashable {
    let id: String
    let name: String
    let summary: String
    let instruction: String
    let tools: ChatToolAccess
    let rounds: Int
    let temperature: Double
    let maximumResponseTokens: Int
    /// A ceiling on the prompt below whatever the window would allow. A small
    /// model given every character it can hold answers worse than one given
    /// the note and the question — the window is what it can read, not what it
    /// can think about.
    let promptLimit: Int?

    static let answers = ChatProfile(
        id: "answers",
        name: "Answers",
        summary: "Reads the open note and answers. No tools, no edits — what a small local model is good at.",
        instruction: """
        Answer the question that was asked, in plain prose and in your own words, \
        from the note in front of you. Two or three sentences unless the question \
        genuinely needs more. Summarise the note only when a summary is what was \
        asked for; otherwise answer the specific thing and leave the rest out. \
        Do not offer to edit anything.
        """,
        tools: .none,
        rounds: 1,
        temperature: 0.3,
        maximumResponseTokens: 520,
        promptLimit: 4_000
    )

    static let assistant = ChatProfile(
        id: "assistant",
        name: "Assistant",
        summary: "Searches your notes, attachments, and calendar. Proposes changes when you ask for one.",
        instruction: "",
        tools: .asked,
        rounds: 8,
        temperature: 0.2,
        maximumResponseTokens: 512,
        promptLimit: nil
    )

    static let editor = ChatProfile(
        id: "editor",
        name: "Editor",
        summary: "Every tool, more rounds to use them. Makes the change rather than describing it.",
        instruction: """
        Prefer making the change to describing it. Read whatever you need before \
        editing, and address only the blocks that have to change.
        """,
        tools: .full,
        rounds: 10,
        temperature: 0.2,
        maximumResponseTokens: 1_024,
        promptLimit: nil
    )

    static let all = [answers, assistant, editor]

    static func named(_ id: String?) -> ChatProfile? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    /// Apple Intelligence and the small local models are the ones that fall
    /// apart holding a tool catalog in mind, so they are handed the profile
    /// that does not give them one.
    static func suggested(for choice: ModelChoice) async -> ChatProfile {
        guard choice.backend != .appleIntelligence else { return .answers }
        guard let billions = await ModelContextWindow.parameterBillions(for: choice) else {
            return choice.backend.usesEndpoint ? .editor : .assistant
        }
        if billions < 8 { return .answers }
        return billions < 30 ? .assistant : .editor
    }
}

enum ChatProfileSettings {
    private static let prefix = "ml.profile."

    /// nil means whatever the chosen model is suited to.
    static func selection(for operation: LocalModelOperation) -> String? {
        UserDefaults.standard.string(forKey: prefix + operation.rawValue)
    }

    static func setSelection(_ id: String?, for operation: LocalModelOperation) {
        guard let id else {
            UserDefaults.standard.removeObject(forKey: prefix + operation.rawValue)
            return
        }
        UserDefaults.standard.set(id, forKey: prefix + operation.rawValue)
    }

    static func profile(for operation: LocalModelOperation, choice: ModelChoice) async -> ChatProfile {
        if let chosen = ChatProfile.named(selection(for: operation)) { return chosen }
        return await ChatProfile.suggested(for: choice)
    }
}
