import WidgetKit
import SwiftUI
import UIKit

struct FavoriteEntry: TimelineEntry {
    let date: Date
    let image: UIImage?
    let site: String
    let key: String?
    let total: Int
}

struct FavoriteProvider: TimelineProvider {
    func placeholder(in context: Context) -> FavoriteEntry {
        FavoriteEntry(date: Date(), image: nil, site: "MediaDeck", key: nil, total: 0)
    }

    func getSnapshot(in context: Context, completion: @escaping (FavoriteEntry) -> Void) {
        completion(entry(at: Date()))
    }

    /// A different random favorite every hour for the next six hours.
    func getTimeline(in context: Context, completion: @escaping (Timeline<FavoriteEntry>) -> Void) {
        let now = Date()
        let entries = (0..<6).map { entry(at: now.addingTimeInterval(Double($0) * 3600)) }
        completion(Timeline(entries: entries, policy: .atEnd))
    }

    func entry(at date: Date) -> FavoriteEntry {
        let feed = WidgetFeed.load()
        guard let pick = feed.items.randomElement(), let dir = AppGroup.widgetDir,
              let image = UIImage(contentsOfFile: dir.appendingPathComponent(pick.file).path) else {
            return FavoriteEntry(date: date, image: nil, site: "", key: nil, total: feed.items.count)
        }
        return FavoriteEntry(date: date, image: image, site: pick.site, key: pick.key, total: feed.items.count)
    }
}

struct RandomFavoriteView: View {
    let entry: FavoriteEntry

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let img = entry.image {
                GeometryReader { g in
                    Image(uiImage: img).resizable().scaledToFill()
                        .frame(width: g.size.width, height: g.size.height).clipped()
                }
                LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                HStack(spacing: 4) {
                    Image(systemName: "heart.fill").foregroundColor(.pink)
                    Text(entry.site).lineLimit(1)
                }
                .font(.caption2.weight(.semibold)).foregroundColor(.white)
                .padding(8)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "heart").font(.title2).foregroundColor(.pink)
                    Text("Favorite something in MediaDeck and it shows up here.")
                        .font(.caption2).multilineTextAlignment(.center).foregroundColor(.secondary)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .widgetURL(URL(string: "mediadeck://favorites" + (entry.key.map { "?key=" + ($0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "") } ?? "")))
        .widgetBackground()
    }
}

extension View {
    /// iOS 17 requires widgets to declare their background.
    @ViewBuilder func widgetBackground() -> some View {
        if #available(iOS 17.0, *) {
            containerBackground(for: .widget) { Color.black }
        } else {
            background(Color.black)
        }
    }
}

@main
struct RandomFavoriteWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "RandomFavorite", provider: FavoriteProvider()) { entry in
            RandomFavoriteView(entry: entry)
        }
        .configurationDisplayName("Random Favorite")
        .description("One of your MediaDeck favorites, changing every hour.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
