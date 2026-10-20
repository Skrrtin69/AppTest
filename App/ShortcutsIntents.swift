import AppIntents
import Foundation

/// Siri / Shortcuts: "Search in MediaDeck" asks for tags, opens the app and runs the search
/// on the current site (or a site named in the Site field).
@available(iOS 16.0, *)
struct SearchMediaDeckIntent: AppIntent {
    static var title: LocalizedStringResource = "Search MediaDeck"
    static var description = IntentDescription("Opens MediaDeck and searches for the tags you give.")
    static var openAppWhenRun = true

    @Parameter(title: "Tags", requestValueDialog: "Which tags?")
    var tags: String

    @Parameter(title: "Site name (optional)")
    var site: String?

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.queueSearch(tags: tags, siteName: site)
        return .result()
    }
}

@available(iOS 16.0, *)
struct MediaDeckShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SearchMediaDeckIntent(), phrases: ["Search in \(.applicationName)", "Find tags in \(.applicationName)"])
    }
}
