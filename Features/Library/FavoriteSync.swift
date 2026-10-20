import Foundation

/// Sends favorites to the user's account on sites that have a favorite address, and
/// remembers which local favorites are synced (cloud icon) vs only on this phone.
@MainActor
final class FavoriteSync: ObservableObject {
    static let shared = FavoriteSync()
    private let key = "syncedFavoriteKeys"
    @Published private(set) var synced: Set<String>

    private init() {
        synced = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    private func persist() { UserDefaults.standard.set(Array(synced), forKey: key) }

    func isSynced(_ post: Post) -> Bool { synced.contains(post.key) }

    /// Only sites with a favorite address and a saved login can sync.
    static func canSync(_ siteID: String) -> GenericAdapter? {
        guard let a = AdapterRegistry.shared.adapter(for: siteID), a.config.favoritePath?.nonEmpty != nil,
              (try? Keychain.credentials(for: siteID)) != nil else { return nil }
        return a
    }

    /// Called after a local favorite/unfavorite. Failures are reported but the local change stays.
    func push(_ post: Post, add: Bool) async {
        guard let adapter = Self.canSync(post.siteID) else { return }
        do {
            try await AuthManager.shared.ensureSession(for: adapter)
            _ = try await adapter.setFavorite(post, add: add)
            if add { synced.insert(post.key) } else { synced.remove(post.key) }
            persist()
        } catch {
            ToastCenter.shared.error(error, prefix: "Saved on this phone, but not on \(adapter.displayName)")
        }
    }

    /// After logging in: offer to upload favorites that only exist on this phone.
    func offerUpload(siteID: String) async {
        guard let adapter = Self.canSync(siteID) else { return }
        let local = LibraryStore.shared.favorites.map { $0.post }.filter { $0.siteID == siteID && !synced.contains($0.key) }
        guard !local.isEmpty else { return }
        guard await Confirm.ask(title: "Sync \(local.count) local favorite\(local.count == 1 ? "" : "s")?",
                                message: "Add the favorites saved on this phone to your \(adapter.displayName) account?",
                                confirm: "Sync") else { return }
        var ok = 0
        for p in local {
            if (try? await adapter.setFavorite(p, add: true)) != nil { synced.insert(p.key); ok += 1 }
        }
        persist()
        ToastCenter.shared.show("Synced \(ok) of \(local.count) favorites to \(adapter.displayName)", style: ok == local.count ? .success : .error)
    }
}

extension GenericAdapter {
    /// POST to add, DELETE to remove, at favoritePath with {id}. Returns the server's message.
    func setFavorite(_ post: Post, add: Bool) async throws -> String {
        guard let p = config.favoritePath?.nonEmpty else { throw AppError.message("Favorites sync isn't set up for this site.") }
        var request = URLRequest(url: try buildURL(path: p, vars: ["id": Self.encode(post.id)]))
        request.httpMethod = add ? "POST" : "DELETE"
        for (k, v) in config.headers { request.setValue(v, forHTTPHeaderField: k) }
        for (k, v) in authHeaders { request.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await client.data(for: request)
        return ErrorParser.message(from: data, contentType: resp.value(forHTTPHeaderField: "Content-Type")) ?? "Done."
    }
}
