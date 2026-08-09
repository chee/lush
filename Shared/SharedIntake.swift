import Foundation

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
        guard let directory = SharedHandoff.directory(id: id) else { return nil }
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
