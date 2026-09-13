import Foundation

/// Where she left off in each note, on this device only: the character the
/// viewport started on. A character rather than a scroll offset, because a
/// resized window rewraps the text and moves every offset in the note.
@MainActor
enum ScrollMemory {
    private static let offsetsKey = "noteScrollTops"
    private static let orderKey = "noteScrollOrder"
    private static let capacity = 400

    private static var offsets: [String: Int] =
        UserDefaults.standard.dictionary(forKey: offsetsKey) as? [String: Int] ?? [:]
    private static var order: [String] =
        UserDefaults.standard.stringArray(forKey: orderKey) ?? []

    static func top(for url: String) -> Int? {
        offsets[url]
    }

    static func remember(_ character: Int, for url: String) {
        guard offsets[url] != character else { return }
        offsets[url] = character
        order.removeAll { $0 == url }
        order.append(url)
        while order.count > capacity, let oldest = order.first {
            order.removeFirst()
            offsets.removeValue(forKey: oldest)
        }
        save()
    }

    static func forget(_ url: String) {
        guard offsets.removeValue(forKey: url) != nil else { return }
        order.removeAll { $0 == url }
        save()
    }

    private static func save() {
        UserDefaults.standard.set(offsets, forKey: offsetsKey)
        UserDefaults.standard.set(order, forKey: orderKey)
    }
}
