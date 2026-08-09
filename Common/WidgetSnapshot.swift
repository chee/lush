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

extension LushWidgetSnapshot {
    static var stored: LushWidgetSnapshot? {
        guard let url = LushShared.container?.appendingPathComponent(LushShared.widgetSnapshotFileName),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LushWidgetSnapshot.self, from: data)
    }
}
