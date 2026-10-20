import Foundation

/// Files shared between MediaDeck, its widget and its share extension.
enum AppGroup {
    static let id = "group.com.skrrtin69.mediadeck"

    static var container: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
    }

    /// Links and pictures sent from the share sheet, waiting for the app to pick them up.
    static var inbox: URL? { folder("Inbox") }
    /// Thumbnails and the list the Random Favorite widget picks from.
    static var widgetDir: URL? { folder("Widget") }

    private static func folder(_ name: String) -> URL? {
        guard let c = container else { return nil }
        let u = c.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
}

/// What the widget can show: one saved thumbnail per favorite.
struct WidgetFeed: Codable {
    struct Item: Codable {
        let file: String
        let site: String
        let key: String
    }
    var items: [Item]

    static var fileURL: URL? { AppGroup.widgetDir?.appendingPathComponent("feed.json") }

    static func load() -> WidgetFeed {
        guard let u = fileURL, let data = try? Data(contentsOf: u),
              let feed = try? JSONDecoder().decode(WidgetFeed.self, from: data) else { return WidgetFeed(items: []) }
        return feed
    }
}
