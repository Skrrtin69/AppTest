import Foundation
import Combine

/// Owns the list of adapters. Source of truth is Documents/adapters.json (visible in the
/// Files app under "On My iPhone › MediaDeck"); the bundled copy is the fallback.
final class AdapterRegistry: ObservableObject {
    static let shared = AdapterRegistry()
    static let fileName = "adapters.json"

    /// All adapters in the user's order (enabled and disabled).
    @Published private(set) var configs: [AdapterConfig] = []
    @Published private(set) var disabledIDs: Set<String> = []
    /// Plain-English problem with the user's file, if any (the bundled list is used meanwhile).
    @Published private(set) var loadProblem: String?
    @Published private(set) var usingBundledFallback = false

    private var adapters: [String: GenericAdapter] = [:]
    private var lastLoadedData: Data?
    private var watcher: DispatchSourceFileSystemObject?
    private var reloadWork: DispatchWorkItem?
    private let defaults = UserDefaults.standard
    private let orderKey = "adapterOrder"
    private let disabledKey = "adapterDisabled"

    static var documentsFile: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(fileName)
    }
    static var bundledFile: URL? { Bundle.main.url(forResource: "adapters", withExtension: "json") }

    private init() {}

    var enabledConfigs: [AdapterConfig] { configs.filter { !disabledIDs.contains($0.id) } }

    func adapter(for id: String) -> GenericAdapter? {
        if let a = adapters[id] { return a }
        guard let c = configs.first(where: { $0.id == id }) else { return nil }
        let a = GenericAdapter(config: c)
        a.session = AuthManager.shared.cachedSession(for: id)
        adapters[id] = a
        return a
    }

    func config(for id: String) -> AdapterConfig? { configs.first { $0.id == id } }
    func displayName(for id: String) -> String { config(for: id)?.displayName ?? id }

    // MARK: Loading

    /// Call once at launch, after the demo server has its port.
    func bootstrap() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: Self.documentsFile.path), let bundled = Self.bundledFile {
            try? fm.copyItem(at: bundled, to: Self.documentsFile)
        }
        reload()
        startWatching()
    }

    func reload() {
        var problem: String?
        var loaded: [AdapterConfig]?
        if let data = try? Data(contentsOf: Self.documentsFile) {
            lastLoadedData = data
            do {
                loaded = try Self.decode(data)
            } catch {
                problem = Self.describe(error)
            }
        }
        if loaded == nil, let b = Self.bundledFile, let data = try? Data(contentsOf: b) {
            loaded = try? Self.decode(data)
            usingBundledFallback = true
        } else {
            usingBundledFallback = false
        }
        loadProblem = problem
        apply(loaded ?? [])
    }

    private func apply(_ list: [AdapterConfig]) {
        let order = defaults.stringArray(forKey: orderKey) ?? []
        let sorted = list.enumerated().sorted { a, b in
            let ia = order.firstIndex(of: a.element.id) ?? (order.count + a.offset)
            let ib = order.firstIndex(of: b.element.id) ?? (order.count + b.offset)
            return ia < ib
        }.map { $0.element }
        // Drop cached adapter objects whose config changed.
        for c in sorted where adapters[c.id]?.config != c { adapters[c.id] = nil }
        configs = sorted
        disabledIDs = Set(defaults.stringArray(forKey: disabledKey) ?? [])
    }

    /// Decodes adapters.json, pointing demo-server URLs at the port actually in use.
    static func decode(_ data: Data) throws -> [AdapterConfig] {
        var text = String(decoding: data, as: UTF8.self)
        let port = MockServer.shared.port
        if port != MockServer.defaultPort {
            text = text.replacingOccurrences(of: "127.0.0.1:\(MockServer.defaultPort)", with: "127.0.0.1:\(port)")
        }
        let list = try JSONDecoder().decode([AdapterConfig].self, from: Data(text.utf8))
        var seen = Set<String>()
        for c in list {
            if seen.contains(c.id) {
                throw AppError.message("Two adapters share the id \"\(c.id)\". Every adapter needs its own id.")
            }
            seen.insert(c.id)
        }
        return list
    }

    /// Turns a JSON decoding error into instructions a non-programmer can follow.
    static func describe(_ error: Error) -> String {
        func where_(_ path: [CodingKey]) -> String {
            var parts: [String] = []
            for k in path {
                if let i = k.intValue { parts.append("adapter #\(i + 1)") } else { parts.append("field \"\(k.stringValue)\"") }
            }
            return parts.isEmpty ? "the file" : parts.joined(separator: ", ")
        }
        guard let de = error as? DecodingError else { return error.localizedDescription }
        switch de {
        case .keyNotFound(let key, let ctx):
            return "In \(where_(ctx.codingPath)), the required field \"\(key.stringValue)\" is missing. Add it (see Settings › Sites & Adapters › Field Guide)."
        case .typeMismatch(_, let ctx):
            return "In \(where_(ctx.codingPath)), the value is the wrong kind (for example text where a number or true/false is expected, or the reverse)."
        case .valueNotFound(_, let ctx):
            return "In \(where_(ctx.codingPath)), the value is empty (null) but this field needs a value."
        case .dataCorrupted(let ctx):
            if ctx.codingPath.isEmpty {
                return "adapters.json isn't valid JSON. Usually this is a missing comma, quote mark, or bracket. Details: \((ctx.underlyingError as NSError?)?.userInfo[NSDebugDescriptionErrorKey] as? String ?? ctx.debugDescription)"
            }
            return "In \(where_(ctx.codingPath)), the value isn't valid: \(ctx.debugDescription) (web addresses must start with http:// or https://; choices must match one of the listed options exactly)."
        @unknown default:
            return error.localizedDescription
        }
    }

    // MARK: Editing

    private func writeFile(_ list: [AdapterConfig]) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        let data = try enc.encode(list)
        lastLoadedData = data
        try data.write(to: Self.documentsFile, options: .atomic)
        loadProblem = nil
        usingBundledFallback = false
        apply(list)
    }

    func upsert(_ config: AdapterConfig, replacing oldID: String? = nil) throws {
        var list = configs
        if let i = list.firstIndex(where: { $0.id == (oldID ?? config.id) }) {
            list[i] = config
        } else {
            list.append(config)
        }
        if oldID != nil, oldID != config.id, list.filter({ $0.id == config.id }).count > 1 {
            throw AppError.message("Another adapter already uses the id \"\(config.id)\".")
        }
        try writeFile(list)
        persistOrder()
    }

    func delete(id: String) throws {
        try writeFile(configs.filter { $0.id != id })
        persistOrder()
    }

    func move(fromOffsets: IndexSet, toOffset: Int) {
        var list = configs
        list.move(fromOffsets: fromOffsets, toOffset: toOffset)
        configs = list
        persistOrder()
    }

    func setEnabled(_ enabled: Bool, id: String) {
        if enabled { disabledIDs.remove(id) } else { disabledIDs.insert(id) }
        defaults.set(Array(disabledIDs), forKey: disabledKey)
    }

    private func persistOrder() {
        defaults.set(configs.map { $0.id }, forKey: orderKey)
    }

    /// Validates an imported file before replacing the current one.
    func importFile(_ data: Data) throws {
        let list: [AdapterConfig]
        do { list = try Self.decode(data) } catch { throw AppError.message(Self.describe(error)) }
        guard !list.isEmpty else { throw AppError.message("That file contains no adapters.") }
        lastLoadedData = data
        try data.write(to: Self.documentsFile, options: .atomic)
        reload()
    }

    /// Ensures the Documents copy exists and returns it for exporting.
    func exportFileURL() throws -> URL {
        if !FileManager.default.fileExists(atPath: Self.documentsFile.path) { try writeFile(configs) }
        return Self.documentsFile
    }

    func resetToBundled() throws {
        guard let b = Self.bundledFile else { return }
        try? FileManager.default.removeItem(at: Self.documentsFile)
        try FileManager.default.copyItem(at: b, to: Self.documentsFile)
        defaults.removeObject(forKey: orderKey)
        defaults.removeObject(forKey: disabledKey)
        adapters.removeAll()
        reload()
    }

    // MARK: Hot reload

    /// Watches the Documents folder; when adapters.json changes on disk (e.g. replaced via
    /// the Files app) the list reloads automatically.
    private func startWatching() {
        let dir = Self.documentsFile.deletingLastPathComponent()
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend], queue: .main)
        src.setEventHandler { [weak self] in self?.scheduleReloadIfChanged() }
        src.setCancelHandler { close(fd) }
        src.resume()
        watcher = src
    }

    private func scheduleReloadIfChanged() {
        reloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            let data = try? Data(contentsOf: Self.documentsFile)
            guard data != self.lastLoadedData else { return }
            self.reload()
            ToastCenter.shared.show(self.loadProblem == nil ? "adapters.json changed — reloaded" : "adapters.json has a problem — see Settings › Sites & Adapters",
                                    style: self.loadProblem == nil ? .success : .error)
        }
        reloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
}
