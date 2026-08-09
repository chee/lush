import Foundation
import UniformTypeIdentifiers

struct SharedHandoff: Codable {
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

enum SharedHandoffError: LocalizedError {
    case missingContainer
    case invalidURL

    var errorDescription: String? {
        switch self {
        case .missingContainer: return "Lush's shared container is unavailable."
        case .invalidURL: return "Couldn't build the handoff URL."
        }
    }
}

extension SharedHandoff {
    static func write(from context: NSExtensionContext) async throws -> URL? {
        let (id, directory) = try prepareDirectory()
        let items = try await loadItems(from: context, into: directory)
        guard !items.isEmpty else {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
        let data = try JSONEncoder().encode(SharedHandoff(createdAt: Date(), items: items))
        try data.write(to: directory.appendingPathComponent("payload.json"), options: .atomic)

        var components = URLComponents()
        components.scheme = "lush"
        components.host = "share"
        components.queryItems = [URLQueryItem(name: "id", value: id)]
        guard let url = components.url else { throw SharedHandoffError.invalidURL }
        return url
    }

    static func directory(id: String) -> URL? {
        LushShared.container?
            .appendingPathComponent("SharedIntake", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
    }

    static func prepareDirectory() throws -> (id: String, directory: URL) {
        let id = UUID().uuidString
        guard let directory = directory(id: id) else { throw SharedHandoffError.missingContainer }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (id, directory)
    }

    static func loadItems(from context: NSExtensionContext, into directory: URL) async throws -> [SharedHandoffItem] {
        let providers = context.inputItems
            .compactMap { $0 as? NSExtensionItem }
            .flatMap { $0.attachments ?? [] }
        var items: [SharedHandoffItem] = []
        for provider in providers {
            if let url = try await loadURL(from: provider) {
                if url.isFileURL {
                    items.append(try copyFileLikeItem(from: url, into: directory))
                } else {
                    items.append(.text(url.absoluteString))
                }
            } else if let image = try await loadImage(from: provider) {
                let name = "image-\(items.count + 1).png"
                try image.write(to: directory.appendingPathComponent(name), options: .atomic)
                items.append(.file(relativePath: name, suggestedName: name))
            } else if let text = try await loadText(from: provider) {
                items.append(.text(text))
            }
        }
        return items
    }

    private static func loadText(from provider: NSItemProvider) async throws -> String? {
        let identifiers = [UTType.plainText.identifier, UTType.text.identifier]
        guard let identifier = identifiers.first(where: { provider.hasItemConformingToTypeIdentifier($0) }) else {
            return nil
        }
        let item = try await provider.loadItem(forTypeIdentifier: identifier)
        if let string = item as? String { return string }
        if let data = item as? Data { return String(data: data, encoding: .utf8) }
        return nil
    }

    private static func loadURL(from provider: NSItemProvider) async throws -> URL? {
        let identifiers = [UTType.fileURL.identifier, UTType.folder.identifier, UTType.url.identifier]
        guard let identifier = identifiers.first(where: { provider.hasItemConformingToTypeIdentifier($0) }) else {
            return nil
        }
        let item = try await provider.loadItem(forTypeIdentifier: identifier)
        if let url = item as? URL { return url }
        if let data = item as? Data { return URL(dataRepresentation: data, relativeTo: nil) }
        if let string = item as? String { return URL(string: string) }
        return nil
    }

    private static func loadImage(from provider: NSItemProvider) async throws -> Data? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else { return nil }
        let item = try await provider.loadItem(forTypeIdentifier: UTType.image.identifier)
        if let data = item as? Data { return data }
        if let url = item as? URL { return try Data(contentsOf: url) }
        return nil
    }

    private static func copyFileLikeItem(from source: URL, into directory: URL) throws -> SharedHandoffItem {
        let scoped = source.startAccessingSecurityScopedResource()
        defer {
            if scoped { source.stopAccessingSecurityScopedResource() }
        }
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory)
        let name = uniqueName(source.lastPathComponent.isEmpty ? "Shared Item" : source.lastPathComponent, in: directory)
        let destination = directory.appendingPathComponent(name, isDirectory: isDirectory.boolValue)
        try FileManager.default.copyItem(at: source, to: destination)
        return .file(relativePath: name, suggestedName: source.lastPathComponent)
    }

    private static func uniqueName(_ proposed: String, in directory: URL) -> String {
        let base = URL(fileURLWithPath: proposed).deletingPathExtension().lastPathComponent
        let ext = URL(fileURLWithPath: proposed).pathExtension
        var candidate = proposed
        var index = 2
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            candidate = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            index += 1
        }
        return candidate
    }
}

private extension NSItemProvider {
    func loadItem(forTypeIdentifier typeIdentifier: String) async throws -> NSSecureCoding? {
        try await withCheckedThrowingContinuation { continuation in
            loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: item)
                }
            }
        }
    }
}
