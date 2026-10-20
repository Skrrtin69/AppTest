import SwiftUI
import BackgroundTasks
import UserNotifications

/// "Watch for new posts" on saved searches. iOS runs a background refresh now and then
/// (when it decides to); the check also runs when the app opens if the last one was more than
/// 15 minutes ago. New posts are counted on the saved search and announced with a
/// notification while the app is in the background.
@MainActor
final class SearchWatch: ObservableObject {
    static let shared = SearchWatch()
    static let taskID = "com.skrrtin69.mediadeck.watch"

    struct State: Codable {
        var enabled = true
        var seen: [String] = []      // post keys of the last first page
        var newCount = 0
        var lastCheck: Date?
    }

    @Published private(set) var states: [String: State] = [:]
    private let key = "searchWatch"

    private init() {
        if let d = UserDefaults.standard.data(forKey: key), let s = try? JSONDecoder().decode([String: State].self, from: d) { states = s }
    }

    func isWatching(_ id: String) -> Bool { states[id]?.enabled == true }
    func newCount(_ id: String) -> Int { states[id]?.newCount ?? 0 }

    func toggle(_ s: SavedSearchItem) {
        if isWatching(s.id) {
            states[s.id] = nil
            persist()
            ToastCenter.shared.show("Stopped watching \(s.name)")
            return
        }
        states[s.id] = State()
        persist()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in }
        ToastCenter.shared.show("Watching \(s.name) for new posts", style: .success)
        Task { await check(only: s.id) }
        Self.schedule()
    }

    /// Opening a saved search clears its "new" count.
    func markSeen(_ id: String) {
        guard states[id] != nil else { return }
        states[id]?.newCount = 0
        persist()
    }

    /// Checks the first page of each watched saved search. Returns the total of new posts.
    @discardableResult
    func check(only id: String? = nil) async -> Int {
        guard !LockManager.shared.decoyActive else { return 0 }
        var total = 0
        var announce: [String] = []
        for s in LibraryStore.shared.savedSearches where states[s.id]?.enabled == true && (id == nil || id == s.id) {
            guard let adapter = AdapterRegistry.shared.adapter(for: s.siteID) else { continue }
            do {
                let tags = TagQuery.parse(s.query).map(TagTranslations.shared.original)
                let r = try await adapter.search(tags: tags, options: SearchOptions(), page: 1)
                let keys = r.posts.filter { !AppSettings.shared.isBlacklisted($0) }.map(\.key)
                var st = states[s.id] ?? State()
                let first = st.lastCheck == nil
                let fresh = first ? 0 : keys.filter { !st.seen.contains($0) }.count
                st.newCount += fresh
                st.seen = keys
                st.lastCheck = Date()
                states[s.id] = st
                total += fresh
                if fresh > 0 { announce.append("\(fresh) new in \(s.name)") }
                DebugLog.log("Watch", "\(s.name): \(keys.count) on page 1, \(fresh) new")
            } catch {
                DebugLog.log("Watch", "\(s.name): \(error.localizedDescription)")
            }
        }
        persist()
        if !announce.isEmpty {
            if UIApplication.shared.applicationState == .active {
                ToastCenter.shared.show(announce.joined(separator: " · "))
            } else {
                let c = UNMutableNotificationContent()
                c.title = "MediaDeck"
                c.body = announce.joined(separator: "\n")
                c.sound = .default
                try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
            }
        }
        return total
    }

    /// On opening the app: check if it's been a while.
    func checkIfDue() {
        let last = states.values.compactMap(\.lastCheck).min() ?? .distantPast
        guard states.values.contains(where: \.enabled), Date().timeIntervalSince(last) > 15 * 60 else { return }
        Task { await check() }
    }

    private func persist() {
        if let d = try? JSONEncoder().encode(states) { UserDefaults.standard.set(d, forKey: key) }
    }

    // MARK: Background refresh

    nonisolated static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            schedule()
            let work = Task { @MainActor in
                let n = await SearchWatch.shared.check()
                DebugLog.log("Watch", "Background refresh done, \(n) new")
                refresh.setTaskCompleted(success: true)
            }
            refresh.expirationHandler = { work.cancel() }
        }
    }

    nonisolated static func schedule() {
        let r = BGAppRefreshTaskRequest(identifier: taskID)
        r.earliestBeginDate = Date().addingTimeInterval(30 * 60)
        do { try BGTaskScheduler.shared.submit(r) } catch { NSLog("[Watch] schedule failed: %@", error.localizedDescription) }
    }
}
