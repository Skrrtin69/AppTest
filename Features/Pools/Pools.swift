import SwiftUI

/// A pool: an ordered set of posts (a comic, a series) defined by the site.
struct Pool: Identifiable, Hashable {
    let id: String
    let name: String
    let count: Int?
    let postIDs: [String]
}

extension GenericAdapter {
    var supportsPools: Bool { config.poolsPath?.nonEmpty != nil }

    /// One page of pools; `query` narrows by name when the site supports {query}.
    func pools(page: Int, query: String) async throws -> [Pool] {
        guard let p = config.poolsPath?.nonEmpty else { return [] }
        let url = try buildURL(path: p, vars: ["page": String(page), "query": Self.encode(query)])
        let json = try await fetchJSON(url)
        let list = DottedPath.evaluate(config.poolsResultsPath ?? "", in: json) as? [Any] ?? []
        return list.compactMap { node in
            guard let id = DottedPath.string(config.poolIDPath?.nonEmpty ?? "id", in: node) else { return nil }
            let name = (DottedPath.string(config.poolNamePath?.nonEmpty ?? "name", in: node) ?? "Pool \(id)")
                .replacingOccurrences(of: "_", with: " ")
            let ids = config.poolPostIDsPath.flatMap { DottedPath.strings($0, in: node, nameKey: nil) } ?? []
            let count = config.poolCountPath.flatMap { DottedPath.string($0, in: node) }.flatMap(Int.init) ?? (ids.isEmpty ? nil : ids.count)
            return Pool(id: id, name: name, count: count, postIDs: ids)
        }
    }

    /// The pool's posts in pool order: from its list of post IDs, or from a search
    /// (poolSearchTemplate, e.g. "pool:{id}") when the site lists no IDs.
    func posts(in pool: Pool, progress: @escaping (Int, Int) -> Void) async throws -> [Post] {
        if !pool.postIDs.isEmpty {
            var out: [Post] = []
            let ids = Array(pool.postIDs.prefix(500))
            for (i, id) in ids.enumerated() {
                if Task.isCancelled { break }
                if let p = try? await fetchPost(id: id) { out.append(p) }
                await MainActor.run { progress(i + 1, ids.count) }
            }
            return out
        }
        guard let t = config.poolSearchTemplate?.nonEmpty else {
            throw AppError.message("This adapter doesn't say how to list a pool's posts (poolPostIDsPath or poolSearchTemplate).")
        }
        let tag = t.replacingOccurrences(of: "{id}", with: pool.id)
        var out: [Post] = []
        var page = config.firstPageIndex
        while out.count < 1000 {
            let r = try await search(tags: [tag], options: SearchOptions(), page: page)
            out += r.posts
            await MainActor.run { progress(out.count, pool.count ?? out.count) }
            guard r.hasNextPage, !r.posts.isEmpty else { break }
            page += 1
        }
        return out
    }
}

/// The Pools tab: pick a site that has pools, browse or search them, open one.
struct PoolsView: View {
    @ObservedObject private var registry = AdapterRegistry.shared
    @State private var siteID: String?
    @State private var pools: [Pool] = []
    @State private var page = 1
    @State private var query = ""
    @State private var loading = false
    @State private var error: String?
    @State private var endReached = false

    var sites: [AdapterConfig] { registry.enabledConfigs.filter { $0.poolsPath?.nonEmpty != nil } }
    var adapter: GenericAdapter? { siteID.flatMap { registry.adapter(for: $0) } }

    var body: some View {
        NavigationView {
            Group {
                if sites.isEmpty {
                    EmptyStateView(icon: "books.vertical", title: "No site has pools set up",
                                   message: "Add poolsPath to an adapter (Settings › Sites & Adapters › Field Guide › Pools).")
                } else {
                    List {
                        Section {
                            Picker("Site", selection: $siteID) {
                                ForEach(sites) { Text($0.displayName).tag(String?.some($0.id)) }
                            }
                            HStack {
                                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                                TextField("Pool name", text: $query)
                                    .textInputAutocapitalization(.never).disableAutocorrection(true)
                                    .onSubmit { Task { await reload() } }
                                    .accessibilityIdentifier("poolSearch")
                            }
                        }
                        Section {
                            ForEach(pools) { p in
                                NavigationLink(destination: PoolDetailView(siteID: siteID ?? "", pool: p)) {
                                    HStack {
                                        Label(p.name, systemImage: "books.vertical")
                                        Spacer()
                                        if let c = p.count { Text("\(c)").foregroundColor(.secondary) }
                                    }
                                }
                                .onAppear { if p.id == pools.last?.id { Task { await loadMore() } } }
                            }
                            if loading { HStack { ProgressView(); Text("Loading pools…").foregroundColor(.secondary) } }
                            if let e = error { Text(e).foregroundColor(.red).font(.footnote) }
                            if !loading && pools.isEmpty && error == nil { Text("No pools found.").foregroundColor(.secondary) }
                        }
                    }
                    .refreshable { await reload() }
                }
            }
            .themedBackground()
            .navigationTitle("Pools")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { if siteID == nil { siteID = sites.first?.id } }
            .task(id: siteID) { await reload() }
        }
        .navigationViewStyle(.stack)
    }

    func reload() async {
        page = 1; pools = []; endReached = false
        await loadMore()
    }

    func loadMore() async {
        guard !loading, !endReached, let a = adapter else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            let more = try await a.pools(page: page, query: query.trimmingCharacters(in: .whitespaces))
            let have = Set(pools.map(\.id))
            let fresh = more.filter { !have.contains($0.id) }
            pools += fresh
            endReached = fresh.isEmpty
            page += 1
        } catch is CancellationError {
        } catch let e as URLError where e.code == .cancelled {
            // A newer load replaced this one (e.g. the site was just chosen); not an error.
        } catch { self.error = error.localizedDescription }
    }
}

struct PoolDetailView: View {
    let siteID: String
    let pool: Pool
    @State private var posts: [Post] = []
    @State private var done = 0
    @State private var total = 0
    @State private var loading = true
    @State private var error: String?
    @State private var viewer: ViewerRequest?
    @State private var collectionBatch: PostBatch?
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 6) {
            if loading {
                HStack { ProgressView(); Text(total > 0 ? "Loading \(done) of \(total)…" : "Loading…").foregroundColor(.secondary) }
                    .padding(.top, 8)
            }
            if let e = error { Text(e).foregroundColor(.red).font(.footnote).padding() }
            if !posts.isEmpty {
                Button { viewer = ViewerRequest(posts: posts, index: 0) } label: {
                    Label("Read from the Start (\(posts.count))", systemImage: "book").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal)
                .accessibilityIdentifier("readPool")
                ScrollView {
                    PostGrid(posts: posts.filter { !settings.isBlacklisted($0) },
                             onTap: { i in viewer = ViewerRequest(posts: posts.filter { !settings.isBlacklisted($0) }, index: i) },
                             onAddToCollection: { collectionBatch = PostBatch(posts: $0) }) { EmptyView() }
                }
            }
            Spacer(minLength: 0)
        }
        .navigationTitle(pool.name)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $viewer) { ViewerView(posts: $0.posts, startIndex: $0.index) }
        .sheet(item: $collectionBatch) { CollectionPickerSheet(posts: $0.posts) }
        .task {
            guard posts.isEmpty, let a = AdapterRegistry.shared.adapter(for: siteID) else { return }
            do {
                posts = try await a.posts(in: pool) { d, t in done = d; total = t }
            } catch { self.error = error.localizedDescription }
            loading = false
        }
    }
}
