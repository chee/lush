import Foundation

struct DockMenuSnapshot: Codable {
    static let fileName = "DockMenuSnapshot.json"
    static let tileImageName = "DockTileImage.png"

    let recents: [DockMenuRecent]

    static var fileURL: URL? {
        LushShared.container?.appendingPathComponent(fileName)
    }

    static var tileImageURL: URL? {
        LushShared.container?.appendingPathComponent(tileImageName)
    }

    static var stored: DockMenuSnapshot {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(DockMenuSnapshot.self, from: data) else {
            return DockMenuSnapshot(recents: [])
        }
        return snapshot
    }

    func write() {
        guard let url = Self.fileURL, let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

struct DockMenuRecent: Codable {
    let title: String
    let url: String
    let modified: TimeInterval
}
