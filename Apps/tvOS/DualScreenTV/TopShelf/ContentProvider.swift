import Foundation
import TVServices

// Extension reads a small sanitized snapshot only: no ROMs, saves or core link.
final class ContentProvider: TVTopShelfContentProvider {
    struct Record: Codable {
        let id: String
        let title: String
        let favourite: Bool
        let lastPlayed: Date?
        let artwork: String?
    }
    override func loadTopShelfContent(completionHandler: @escaping (TVTopShelfContent?) -> Void) {
        guard let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.org.example.DualScreenTV"),
              let data = try? Data(contentsOf: group.appendingPathComponent("Library/Caches/TopShelf/shelf.plist")), data.count <= 64 * 1024,
              let records = try? PropertyListDecoder().decode([Record].self, from: data), records.count <= 20 else {
            completionHandler(nil); return
        }
        var seen: Set<String> = []
        let valid = records.filter { record in
            record.id.utf8.count == 64 && record.id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
                && record.title.utf8.count <= 240 && seen.insert(record.id).inserted
        }
        var sections: [TVTopShelfItemCollection<TVTopShelfSectionedItem>] = []
        for (title, records) in [("Recently Played", valid.filter { $0.lastPlayed != nil }), ("Favourites", valid.filter(\.favourite))] where !records.isEmpty {
            let items = records.prefix(10).map { record in
                let item = TVTopShelfSectionedItem(identifier: title + record.id)
                item.title = record.title; item.imageShape = .hdtv
                let directory = group.appendingPathComponent("Library/Caches/TopShelf")
                var picture = directory.appendingPathComponent("placeholder.png")
                if let name = record.artwork, name.hasSuffix(".png"), name.utf8.count == 68,
                   name.dropLast(4).utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) {
                    let custom = directory.appendingPathComponent(name)
                    if FileManager.default.fileExists(atPath: custom.path) { picture = custom }
                }
                item.setImageURL(picture, for: [.screenScale1x, .screenScale2x])
                let action = TVTopShelfAction(url: URL(string: "dualscreentv://game/" + record.id)!)
                item.playAction = action; item.displayAction = action
                return item
            }
            let section = TVTopShelfItemCollection(items: items); section.title = title
            sections.append(section)
        }
        completionHandler(sections.isEmpty ? nil : TVTopShelfSectionedContent(sections: sections))
    }
}
