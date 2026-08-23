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
    private let journal: HandoffJournal?

    init(payload: Payload, handoffDirectory: URL? = nil) {
        self.payload = payload
        self.handoffDirectory = handoffDirectory
        journal = handoffDirectory.map(HandoffJournal.init)
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

    var completedHandoffItems: Set<Int> {
        journal?.snapshot.completed ?? []
    }

    func completedHandoffChildren(for index: Int) -> Set<String> {
        let prefix = "\(index):"
        let children = journal?.snapshot.completedChildren ?? []
        return Set(children.compactMap { key in
            guard key.hasPrefix(prefix) else { return nil }
            return String(key.dropFirst(prefix.count))
        })
    }

    func handoffCreatedUrl(for operationKey: String) -> String? {
        journal?.snapshot.createdUrls[operationKey]
    }

    func markHandoffItemsCompleted(_ indexes: Set<Int>) -> Bool {
        journal?.mutate { $0.completed.formUnion(indexes) } ?? true
    }

    func markHandoffChildCompleted(index: Int, relativePath: String) -> Bool {
        journal?.mutate { $0.completedChildren.insert("\(index):\(relativePath)") } ?? true
    }

    func markHandoffCreatedUrl(_ url: String, for operationKey: String) -> Bool {
        journal?.mutate { $0.createdUrls[operationKey] = url } ?? true
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

private final class HandoffJournal: @unchecked Sendable {
    private let fileUrl: URL
    private let lock = NSLock()
    private var progress: SharedImportProgress

    init(directory: URL) {
        fileUrl = directory.appendingPathComponent("progress.json")
        if let data = boundedHandoffData(at: fileUrl, maximumSize: 16_777_216),
           let decoded = try? JSONDecoder().decode(SharedImportProgress.self, from: data) {
            progress = decoded
        } else {
            progress = SharedImportProgress()
        }
    }

    var snapshot: SharedImportProgress {
        lock.lock()
        defer { lock.unlock() }
        return progress
    }

    /// The caller decides from the result whether a retry would repeat work it
    /// has already done, so the write has to land before the answer comes back
    /// — a batched flush would report the previous change's fate, not this one's.
    func mutate(_ change: (inout SharedImportProgress) -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        change(&progress)
        return (try? JSONEncoder().encode(progress).write(to: fileUrl, options: .atomic)) != nil
    }
}

private struct SharedImportProgress: Codable {
    var completed: Set<Int>
    var completedChildren: Set<String>
    var createdUrls: [String: String]

    init(
        completed: Set<Int> = [],
        completedChildren: Set<String> = [],
        createdUrls: [String: String] = [:]
    ) {
        self.completed = completed
        self.completedChildren = completedChildren
        self.createdUrls = createdUrls
    }

    private enum CodingKeys: String, CodingKey {
        case completed
        case completedChildren
        case createdUrls
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        completed = try container.decodeIfPresent(Set<Int>.self, forKey: .completed) ?? []
        completedChildren = try container.decodeIfPresent(Set<String>.self, forKey: .completedChildren) ?? []
        createdUrls = try container.decodeIfPresent([String: String].self, forKey: .createdUrls) ?? [:]
    }
}

private func boundedHandoffData(at url: URL, maximumSize: Int) -> Data? {
    guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
          let size = values.fileSize,
          size <= maximumSize,
          let data = try? Data(contentsOf: url, options: .mappedIfSafe),
          data.count <= maximumSize else { return nil }
    return data
}
