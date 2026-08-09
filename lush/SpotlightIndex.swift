import Foundation
import UniformTypeIdentifiers

#if canImport(CoreSpotlight)
import CoreSpotlight

actor SpotlightIndex {
    private let index = CSSearchableIndex(name: "LushNotes")
    private let domainIdentifier = "party.chee.patchwork.lush.notes"
    private var indexedDigests: [String: String] = [:]

    func index(url: String, title: String, spansJson: String) {
        let spans = SpanNode.decodeList(spansJson)
        let noteTitle = RichText.title(from: spans)
        let displayTitle = noteTitle.isEmpty ? (title.isEmpty ? "Untitled" : title) : noteTitle
        let body = Self.plainText(from: spans)
        let digest = "\(displayTitle)\n\(body)"
        guard indexedDigests[url] != digest else { return }

        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = displayTitle
        attributes.displayName = displayTitle
        attributes.contentDescription = body.isEmpty ? nil : Self.snippet(from: body, limit: 900)
        attributes.textContent = body
        attributes.keywords = ["Lush", "note"]
        if let event = spans.lazy.compactMap({ span -> BlockValue? in
            guard case .block(let block) = span, block.calendarEventTitle != nil else { return nil }
            return block
        }).first {
            attributes.keywords?.append(contentsOf: ["calendar", "event"])
            attributes.startDate = event.calendarEventStart
            attributes.endDate = event.calendarEventEnd
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

    private static func plainText(from spans: [SpanNode]) -> String {
        var parts: [String] = []
        for span in spans {
            switch span {
            case .block(let block):
                if block.isEmbedBlock, let html = block.htmlSource {
                    parts.append(html)
                }
                if let event = block.calendarEventSearchText {
                    parts.append(event)
                }
            case .text(let text, _):
                parts.append(text)
            }
        }
        return parts.joined(separator: "\n")
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
    func index(url: String, title: String, spansJson: String) {}
    func remove(url: String) {}
}
#endif
