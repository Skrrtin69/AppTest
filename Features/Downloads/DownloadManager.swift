import Foundation
import CoreData
import Photos

struct DownloadItem: Identifiable, Hashable {
    enum State: String { case queued, downloading, paused, failed, completed }
    let id: String
    let post: Post
    var state: State
    var progress: Double
    var bytesTotal: Int64
    var relativePath: String?
    var error: String?
    let createdAt: Date
    let remoteURL: URL

    var fileURL: URL? { relativePath.map { DownloadManager.root.appendingPathComponent($0) } }
    var filename: String { relativePath.map { ($0 as NSString).lastPathComponent } ?? post.id }
}

/// Download queue. Uses a background URLSession (when enabled) so transfers continue while
/// the app is suspended; queue state lives in Core Data and is restored on relaunch.
/// All state is touched on the main thread (the session's delegate queue is `.main`).
final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()
    static let backgroundID = "com.skrrtin69.mediadeck.downloads"

    @Published private(set) var items: [DownloadItem] = []

    static var root: URL {
        let u = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// Set by the app delegate when iOS relaunches us for background session events.
    var backgroundCompletionHandler: (() -> Void)?
    private var session: URLSession!
    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var lastProgressPublish: [String: Double] = [:]
    /// Items the user chose to download despite the size limit.
    private var sizeOverride = Set<String>()
    private var ctx: NSManagedObjectContext { CoreDataStack.shared.context }
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    /// Items hidden while their Undo toast is showing; really deleted afterwards.
    @Published private(set) var pendingRemoval: Set<String> = []
    /// Decoy mode shows no downloads.
    private var shown: [DownloadItem] { LockManager.shared.decoyActive ? [] : items }
    var completed: [DownloadItem] { shown.filter { $0.state == .completed && !pendingRemoval.contains($0.id) } }

    /// Deletes after a 5-second Undo window.
    func removeWithUndo(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        pendingRemoval.formUnion(ids)
        ToastCenter.shared.show("Deleted \(ids.count) item\(ids.count == 1 ? "" : "s")", actionTitle: "Undo") { [weak self] in
            self?.pendingRemoval.subtract(ids)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.5) { [weak self] in
            guard let self = self else { return }
            let still = ids.filter { self.pendingRemoval.contains($0) }
            self.pendingRemoval.subtract(still)
            self.remove(still)
        }
    }
    var queue: [DownloadItem] { shown.filter { $0.state != .completed } }

    // MARK: Startup

    /// Set after a background transfer's file turned out to be unreadable (some sideload
    /// setups don't give the app access to the download daemon's files).
    static let backgroundUnsupportedKey = "backgroundDownloadsUnsupported"
    private(set) var usingBackground = false

    var backgroundUnsupported: Bool { UserDefaults.standard.bool(forKey: Self.backgroundUnsupportedKey) }

    private func makeSession(background: Bool) {
        let cfg: URLSessionConfiguration
        if background {
            cfg = .background(withIdentifier: Self.backgroundID)
            cfg.sessionSendsLaunchEvents = true
            cfg.isDiscretionary = false
        } else {
            cfg = .default
            cfg.urlCache = nil
        }
        cfg.httpMaximumConnectionsPerHost = 8
        cfg.timeoutIntervalForRequest = 60
        usingBackground = background
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: .main)
    }

    func bootstrap() {
        makeSession(background: AppSettings.shared.backgroundDownloads && !backgroundUnsupported)
        loadFromStore()
        Task { @MainActor in
            let live = await session.allTasks.compactMap { $0 as? URLSessionDownloadTask }
            for t in live {
                if let id = t.taskDescription, items.contains(where: { $0.id == id }) { tasks[id] = t } else { t.cancel() }
            }
            // Items that were mid-transfer when the app died go back in the queue.
            for i in items.indices where items[i].state == .downloading && tasks[items[i].id] == nil {
                items[i].state = .queued
            }
            persistAll()
            schedule()
        }
    }

    private func loadFromStore() {
        let r = NSFetchRequest<DownloadMO>(entityName: "Download")
        r.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
        items = ((try? ctx.fetch(r)) ?? []).compactMap { mo in
            guard let post = try? decoder.decode(Post.self, from: mo.postData), let url = URL(string: mo.remoteURL) else { return nil }
            return DownloadItem(id: mo.id, post: post, state: DownloadItem.State(rawValue: mo.state) ?? .queued,
                                progress: mo.progress, bytesTotal: mo.bytesTotal, relativePath: mo.relativePath,
                                error: mo.errorMessage, createdAt: mo.createdAt, remoteURL: url)
        }
    }

    private func mo(_ id: String) -> DownloadMO? {
        let r = NSFetchRequest<DownloadMO>(entityName: "Download")
        r.predicate = NSPredicate(format: "id == %@", id)
        r.fetchLimit = 1
        return try? ctx.fetch(r).first
    }

    private func persist(_ item: DownloadItem, resumeData: Data?? = nil) {
        let m = mo(item.id) ?? {
            let n = DownloadMO(context: ctx)
            n.id = item.id
            n.createdAt = item.createdAt
            n.postKey = item.post.key
            n.siteID = item.post.siteID
            n.postData = (try? encoder.encode(item.post)) ?? Data()
            n.remoteURL = item.remoteURL.absoluteString
            n.tagsText = item.post.tags.joined(separator: " ")
            n.mediaType = item.post.mediaType.rawValue
            return n
        }()
        m.state = item.state.rawValue
        m.progress = item.progress
        m.bytesTotal = item.bytesTotal
        m.relativePath = item.relativePath
        m.errorMessage = item.error
        if let rd = resumeData { m.resumeData = rd }
        CoreDataStack.shared.save()
    }

    private func persistAll() { items.forEach { persist($0) } }

    private func update(_ id: String, persist save: Bool = true, _ change: (inout DownloadItem) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[i])
        if save { persist(items[i]) }
    }

    // MARK: Enqueue

    /// Adds posts to the queue using the quality and filename settings.
    @MainActor
    func enqueue(_ posts: [Post]) async {
        guard !LockManager.shared.decoyActive else { return }
        let settings = AppSettings.shared
        guard !posts.isEmpty else { return }
        // Mobile data: confirm batches and videos first.
        if settings.warnOnCellular, NetworkStatus.shared.onMeteredData,
           posts.count >= 5 || posts.contains(where: { $0.mediaType == .video }) {
            let what = posts.count == 1 ? "this video" : "\(posts.count) items"
            guard await Confirm.ask(title: "You're on mobile data",
                                    message: "Download \(what) over cellular? (You can turn this question off in Settings › Downloads.)",
                                    confirm: "Download") else { return }
        }
        var added = 0, skipped = 0
        for (offset, post) in posts.enumerated() {
            // Duplicate check: same post or same file already downloaded, and the file is still there.
            if let existing = items.first(where: { ($0.post.key == post.key || $0.remoteURL == post.mediaURL) && $0.state != .failed }) {
                if existing.state != .completed || existing.fileURL.map({ FileManager.default.fileExists(atPath: $0.path) }) == true {
                    skipped += 1
                    continue
                }
                remove([existing.id])     // record without its file: download again
            }
            let url: URL
            if let adapter = AdapterRegistry.shared.adapter(for: post.siteID) {
                url = (try? await adapter.fetchMediaURL(for: post, quality: settings.downloadQuality)) ?? post.mediaURL
            } else {
                url = settings.downloadQuality == .original ? post.mediaURL : (post.sampleURL ?? post.thumbnailURL)
            }
            let rel = Self.relativePath(for: post, url: url, index: offset + 1, settings: settings)
            let item = DownloadItem(id: UUID().uuidString, post: post, state: .queued, progress: 0, bytesTotal: 0,
                                    relativePath: rel, error: nil, createdAt: Date(), remoteURL: url)
            items.removeAll { $0.post.key == post.key && $0.state == .failed }
            items.append(item)
            persist(item)
            added += 1
        }
        if added > 0 { ToastCenter.shared.show(added == 1 ? "Download started" : "\(added) downloads queued", style: .success) }
        if skipped > 0 && added == 0 { ToastCenter.shared.show(skipped == 1 ? "Already downloaded or queued" : "\(skipped) already downloaded or queued") }
        schedule()
    }

    /// Applies the folder and filename templates. Tokens: {site} {id} {index} {type} {date}.
    static func relativePath(for post: Post, url: URL, index: Int, settings: AppSettings) -> String {
        let date: String = {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date())
        }()
        func fill(_ t: String) -> String {
            t.replacingOccurrences(of: "{site}", with: post.siteID)
                .replacingOccurrences(of: "{id}", with: post.id)
                .replacingOccurrences(of: "{index}", with: String(index))
                .replacingOccurrences(of: "{type}", with: post.mediaType.rawValue)
                .replacingOccurrences(of: "{date}", with: date)
        }
        func sanitize(_ s: String) -> String {
            let bad = CharacterSet(charactersIn: "\\:*?\"<>|\n\r").union(.controlCharacters)
            return s.components(separatedBy: bad).joined(separator: "_").trimmingCharacters(in: .whitespaces)
        }
        var ext = url.pathExtension.lowercased()
        if ext.isEmpty || ext.count > 5 {
            ext = post.mediaType == .video ? "mp4" : (post.mediaType == .gif ? "gif" : "jpg")
        }
        let folder = fill(settings.folderTemplate).split(separator: "/").map { sanitize(String($0)) }.filter { !$0.isEmpty && $0 != ".." }.joined(separator: "/")
        let name = sanitize(fill(settings.filenameTemplate).replacingOccurrences(of: "/", with: "_")).nonEmpty ?? post.id
        var rel = folder.isEmpty ? "\(name).\(ext)" : "\(folder)/\(name).\(ext)"
        // Avoid overwriting an existing file.
        var n = 2
        while FileManager.default.fileExists(atPath: root.appendingPathComponent(rel).path) {
            rel = folder.isEmpty ? "\(name)-\(n).\(ext)" : "\(folder)/\(name)-\(n).\(ext)"
            n += 1
        }
        return rel
    }

    // MARK: Scheduling

    func schedule() {
        guard session != nil else { return }
        let max = AppSettings.shared.maxDownloads
        var running = items.filter { $0.state == .downloading }.count
        for item in items where item.state == .queued {
            guard running < max else { break }
            start(item)
            running += 1
        }
    }

    private func start(_ item: DownloadItem) {
        let task: URLSessionDownloadTask
        if let rd = mo(item.id)?.resumeData, !rd.isEmpty {
            task = session.downloadTask(withResumeData: rd)
        } else {
            var req = URLRequest(url: item.remoteURL)
            let client = AdapterRegistry.shared.adapter(for: item.post.siteID)?.client ?? NetworkClient.forMedia(item.remoteURL)
            for (k, v) in client.mediaHeaders { req.setValue(v, forHTTPHeaderField: k) }
            task = session.downloadTask(with: req)
        }
        task.taskDescription = item.id
        tasks[item.id] = task
        update(item.id) { $0.state = .downloading; $0.error = nil }
        task.resume()
    }

    // MARK: Controls

    func pause(_ id: String) {
        guard let task = tasks[id] else { return }
        update(id) { $0.state = .paused }
        task.cancel(byProducingResumeData: { [weak self] data in
            DispatchQueue.main.async {
                guard let self = self, let i = self.items.firstIndex(where: { $0.id == id }) else { return }
                self.tasks[id] = nil
                self.persist(self.items[i], resumeData: .some(data))
                self.schedule()
            }
        })
    }

    func resume(_ id: String) {
        update(id) { $0.state = .queued }
        schedule()
    }

    /// "Download anyway" for an item skipped by the size limit.
    func downloadAnyway(_ id: String) {
        sizeOverride.insert(id)
        retry(id)
    }

    var failedCount: Int { shown.filter { $0.state == .failed }.count }

    /// Writes the files to one ZIP in the temp folder and offers to save it in Files.
    func exportZIP(_ list: [DownloadItem]) {
        let entries = list.compactMap { i in i.fileURL.map { ZipWriter.Entry(name: i.filename, url: $0) } }
        guard !entries.isEmpty else { return }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmm"
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("MediaDeck-\(f.string(from: Date())).zip")
        ToastCenter.shared.show("Making ZIP of \(entries.count) files…")
        Task.detached(priority: .userInitiated) {
            do {
                try? FileManager.default.removeItem(at: dest)
                try ZipWriter.write(entries, to: dest)
                await MainActor.run { Presenter.exportToFiles([dest]) }
            } catch {
                ToastCenter.shared.error(error, prefix: "Couldn't make the ZIP")
            }
        }
    }

    func retry(_ id: String) {
        update(id) { $0.state = .queued; $0.error = nil; $0.progress = 0 }
        if let m = mo(id) { m.resumeData = nil; CoreDataStack.shared.save() }
        schedule()
    }

    func cancel(_ id: String) {
        tasks[id]?.cancel()
        tasks[id] = nil
        remove([id])
        schedule()
    }

    func pauseAll() { items.filter { $0.state == .downloading }.forEach { pause($0.id) } }
    func resumeAll() { items.filter { $0.state == .paused }.forEach { resume($0.id) } }
    func retryFailed() { items.filter { $0.state == .failed }.forEach { retry($0.id) } }
    func clearFinishedFromQueue() { remove(items.filter { $0.state == .failed }.map { $0.id }) }

    /// Deletes records and their files.
    func remove(_ ids: [String]) {
        for id in ids {
            tasks[id]?.cancel(); tasks[id] = nil
            if let item = items.first(where: { $0.id == id }), item.state == .completed, let f = item.fileURL {
                try? FileManager.default.removeItem(at: f)
            }
            if let m = mo(id) { ctx.delete(m) }
        }
        items.removeAll { ids.contains($0.id) }
        CoreDataStack.shared.save()
    }

    func removeAll() {
        // Decoy mode: looks done, touches nothing.
        guard !LockManager.shared.decoyActive else { return }
        remove(items.map { $0.id })
        try? FileManager.default.removeItem(at: Self.root)
    }

    // MARK: Export

    @MainActor
    func exportToPhotos(_ list: [DownloadItem]) async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            ToastCenter.shared.show("MediaDeck isn't allowed to add to Photos. Enable it in the iOS Settings app › MediaDeck › Photos.", style: .error)
            return
        }
        let exportable = list.filter { item in
            guard let ext = item.fileURL?.pathExtension.lowercased() else { return false }
            return ext != "webm"
        }
        let skipped = list.count - exportable.count
        do {
            try await PHPhotoLibrary.shared().performChanges {
                for item in exportable {
                    guard let f = item.fileURL else { continue }
                    let req = PHAssetCreationRequest.forAsset()
                    req.addResource(with: item.post.mediaType == .video ? .video : .photo, fileURL: f, options: nil)
                }
            }
            var msg = "Saved \(exportable.count) to Photos"
            if skipped > 0 { msg += " (\(skipped) WebM skipped — Photos can't store WebM; use Export to Files)" }
            ToastCenter.shared.show(msg, style: exportable.isEmpty ? .error : .success)
        } catch {
            ToastCenter.shared.error(error, prefix: "Photos export failed")
        }
    }

    func exportToFiles(_ list: [DownloadItem]) {
        Presenter.exportToFiles(list.compactMap { $0.fileURL })
    }
}

// MARK: - URLSessionDownloadDelegate (called on the main queue)

extension DownloadManager: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription else { return }
        // Size limit: decided as soon as the server says how big the file is.
        let limitMB = AppSettings.shared.maxDownloadMB
        if limitMB > 0, totalBytesExpectedToWrite > Int64(limitMB * 1_048_576), !sizeOverride.contains(id) {
            let size = ByteCountFormatter.string(fromByteCount: totalBytesExpectedToWrite, countStyle: .file)
            update(id) { $0.state = .failed; $0.error = "Skipped: \(size) is over your \(limitMB < 1 ? String(format: "%.1f", limitMB) : String(Int(limitMB))) MB limit" }
            downloadTask.cancel()
            tasks[id] = nil
            schedule()
            return
        }
        let p = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
        // Throttle UI updates to whole percents.
        if abs(p - (lastProgressPublish[id] ?? -1)) < 0.01 && p < 1 { return }
        lastProgressPublish[id] = p
        update(id, persist: false) { $0.progress = p; $0.bytesTotal = totalBytesExpectedToWrite }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription, let item = items.first(where: { $0.id == id }) else { return }
        if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            update(id) { $0.state = .failed; $0.error = "Server answered \(http.statusCode)" }
            return
        }
        // Must move the file before this method returns.
        guard let dest = item.fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            do {
                try FileManager.default.moveItem(at: location, to: dest)
            } catch {
                try FileManager.default.copyItem(at: location, to: dest)
            }
            update(id) { $0.state = .completed; $0.progress = 1; $0.error = nil }
            if let m = mo(id) { m.resumeData = nil; CoreDataStack.shared.save() }
        } catch {
            if session === self.session, usingBackground, Self.isPermissionError(error) {
                fallBackToForeground()
                return
            }
            update(id) { $0.state = .failed; $0.error = "Couldn't save file: \(error.localizedDescription)" }
        }
    }

    static func isPermissionError(_ error: Error) -> Bool {
        let e = error as NSError
        return e.domain == NSCocoaErrorDomain && [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(e.code)
    }

    /// Background transfers finish into a file this app may not read on some sideload setups.
    /// Remember that, switch to a regular session, and restart everything in flight.
    private func fallBackToForeground() {
        UserDefaults.standard.set(true, forKey: Self.backgroundUnsupportedKey)
        let old = session!
        makeSession(background: false)
        tasks.removeAll()
        for i in items.indices where items[i].state == .downloading || items[i].state == .failed {
            items[i].state = .queued
            items[i].progress = 0
            items[i].error = nil
            if let m = mo(items[i].id) { m.resumeData = nil }
            persist(items[i])
        }
        old.invalidateAndCancel()
        ToastCenter.shared.show("Background downloads aren't available on this device — switched to regular downloads.")
        schedule()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard session === self.session, let id = task.taskDescription else { return }
        tasks[id] = nil
        lastProgressPublish[id] = nil
        defer { schedule() }
        guard let error = error as NSError? else { return }
        guard let item = items.first(where: { $0.id == id }) else { return }
        if item.state == .paused || item.state == .completed { return }
        if error.code == NSURLErrorCancelled && item.state != .downloading { return }
        let rd = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        update(id) { $0.state = .failed; $0.error = error.localizedDescription }
        if let rd = rd, let i = items.firstIndex(where: { $0.id == id }) { persist(items[i], resumeData: .some(rd)) }
        ToastCenter.shared.show("Download failed: \(error.localizedDescription)", style: .error)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            self.backgroundCompletionHandler?()
            self.backgroundCompletionHandler = nil
        }
    }
}
