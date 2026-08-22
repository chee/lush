import Foundation
import UniformTypeIdentifiers

#if canImport(CoreSpotlight)
import CoreSpotlight

actor SpotlightIndex {
    private let index = CSSearchableIndex(name: "LushNotes")
    private let domainIdentifier = "party.chee.patchwork.lush.notes"
    private var indexedDigests: [String: String] = [:]

    func index(url: String, title: String, body: String, eventStart: Date?, eventEnd: Date?) {
        let displayTitle = title.isEmpty ? "Untitled" : title
        let digest = "\(displayTitle)\n\(body)"
        guard indexedDigests[url] != digest else { return }

        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = displayTitle
        attributes.displayName = displayTitle
        attributes.contentDescription = body.isEmpty ? nil : Self.snippet(from: body, limit: 900)
        attributes.textContent = body
        attributes.keywords = ["Lush", "note"]
        if let eventStart {
            attributes.keywords?.append(contentsOf: ["calendar", "event"])
            attributes.startDate = eventStart
            attributes.endDate = eventEnd
        }

        var components = URLComponents()
        components.scheme = "lush"
        components.host = "show"
        components.queryItems = [URLQueryItem(name: "doc", value: url)]
        attributes.url = components.url

        let item = CSSearchableItem(
            uniqueIdentifier: url,
            domainIdentifier: domainIdentifier,
            attributeSet: attributes
        )
        item.expirationDate = .distantFuture
        indexedDigests[url] = digest
        index.indexSearchableItems([item]) { _ in }
    }

    func remove(url: String) {
        indexedDigests[url] = nil
        index.deleteSearchableItems(withIdentifiers: [url]) { _ in }
    }

    func reset() {
        indexedDigests.removeAll()
    }

    private static func snippet(from text: String, limit: Int) -> String {
        var snippet = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if snippet.count > limit {
            snippet = String(snippet.prefix(limit)) + "..."
        }
        return snippet
    }
}
#else
actor SpotlightIndex {
    func index(url: String, title: String, body: String, eventStart: Date?, eventEnd: Date?) {}
    func remove(url: String) {}
}
#endif
