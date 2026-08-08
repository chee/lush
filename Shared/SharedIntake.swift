import Foundation

struct LushWidgetSnapshot: Codable, Equatable {
    let updatedAt: Date
    let defaultFolderUrl: String?
    let folders: [LushWidgetFolderSnapshot]
}

struct LushWidgetFolderSnapshot: Codable, Equatable {
    let url: String
    let title: String
    let path: String
    let totalItemCount: Int
    let items: [LushWidgetItemSnapshot]
}

struct LushWidgetItemSnapshot: Codable, Equatable {
    let url: String
    let title: String
    let preview: String
    let kind: String
}

struct IncomingContent: Identifiable {
    let id = UUID()
    enum Payload {
        case text(String)
        case file(URL)
        case batch([Payload])
    }
    let payload: Payload
    let handoffDirectory: URL?

    init(payload: Payload, handoffDirectory: URL? = nil) {
        self.payload = payload
        self.handoffDirectory = handoffDirectory
    }

    var flattenedPayloads: [Payload] {
        switch payload {
        case .text, .file:
            return [payload]
        case .batch(let payloads):
            return payloads.flatMap { IncomingContent(payload: $0).flattenedPayloads }
        }
    }

    var displayTitle: String {
        switch payload {
        case .text(let text):
            let title = String(text.prefix(60)).components(separatedBy: .newlines).first ?? ""
            return title.isEmpty ? "Shared Text" : title
        case .file(let url):
            return url.lastPathComponent.isEmpty ? "Shared File" : url.lastPathComponent
        case .batch(let payloads):
            if payloads.count == 1 {
                return IncomingContent(payload: payloads[0]).displayTitle
            }
            return "\(payloads.count) Shared Items"
        }
    }

    var textDisplayTitle: String {
        for payload in flattenedPayloads {
            if case .text(let text) = payload {
                let title = String(text.prefix(60)).components(separatedBy: .newlines).first ?? ""
                if !title.isEmpty { return title }
            }
        }
        return "Shared Text"
    }

    func cleanupHandoff() {
        guard let handoffDirectory else { return }
        try? FileManager.default.removeItem(at: handoffDirectory)
    }

    static func sharedHandoff(id: String) -> IncomingContent? {
        guard let root = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedHandoff.appGroupIdentifier
        ) else { return nil }
        let directory = root
            .appendingPathComponent("SharedIntake", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
        let payloadUrl = directory.appendingPathComponent("payload.json")
        guard let data = try? Data(contentsOf: payloadUrl),
              let handoff = try? JSONDecoder().decode(SharedHandoff.self, from: data) else {
            return nil
        }
        let payloads = handoff.items.compactMap { item -> Payload? in
            switch item {
            case .text(let text):
                return .text(text)
            case .file(let relativePath, _):
                return .file(directory.appendingPathComponent(relativePath))
            }
        }
        guard !payloads.isEmpty else { return nil }
        return IncomingContent(payload: .batch(payloads), handoffDirectory: directory)
    }
}

struct SharedHandoff: Codable {
    static let appGroupIdentifier = "group.party.chee.patchwork.lush"

    let createdAt: Date
    let items: [SharedHandoffItem]
}

enum SharedHandoffItem: Codable {
    case text(String)
    case file(relativePath: String, suggestedName: String)

    private enum CodingKeys: String, CodingKey {
        case kind, text, relativePath, suggestedName
    }

    private enum Kind: String, Codable {
        case text, file
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .text:
            self = .text(try container.decode(String.self, forKey: .text))
        case .file:
            self = .file(
                relativePath: try container.decode(String.self, forKey: .relativePath),
                suggestedName: try container.decode(String.self, forKey: .suggestedName)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode(Kind.text, forKey: .kind)
            try container.encode(text, forKey: .text)
        case .file(let relativePath, let suggestedName):
            try container.encode(Kind.file, forKey: .kind)
            try container.encode(relativePath, forKey: .relativePath)
            try container.encode(suggestedName, forKey: .suggestedName)
        }
    }
}
