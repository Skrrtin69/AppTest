import SwiftUI
import UIKit

/// A reverse image search service the user describes in JSON, like an adapter: where to send
/// the picture, and where the matches are in the answer. No service is built in; the demo
/// engine talks to the app's own demo server.
struct ReverseEngine: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var enabled: Bool = true
    /// "url" sends the picture's address ({url} in requestURL); "upload" posts the file itself.
    var mode: String = "url"
    /// Request address. Placeholders: {url} (the picture's address, encoded) and {api_key}.
    var requestURL: String
    /// Form field name for the file in "upload" mode.
    var uploadField: String? = "file"
    /// Where the list of matches is in the answer.
    var resultsPath: String
    /// Inside one match:
    var similarityPath: String?
    var thumbnailPath: String?
    var sourceURLPath: String?
    var titlePath: String?
    /// Matches below this similarity (0–100) are hidden.
    var minSimilarity: Double? = nil
    /// Optional page where the user gets an API key.
    var apiKeyPageURL: String? = nil

    static func demo(port: UInt16) -> ReverseEngine {
        ReverseEngine(id: "demo-reverse", name: "Demo Reverse Search", mode: "upload",
                      requestURL: "http://127.0.0.1:\(port)/rs/search?api_key={api_key}",
                      uploadField: "file", resultsPath: "results",
                      similarityPath: "header.similarity", thumbnailPath: "header.thumbnail",
                      sourceURLPath: "data.urls[0]", titlePath: "data.title", minSimilarity: 0)
    }
}

/// One match from a reverse search.
struct ReverseMatch: Identifiable {
    let id = UUID()
    let similarity: Double?
    let thumbnail: URL?
    let source: URL?
    let title: String?
}

/// Engines are kept in Documents/reverse_search.json, so they can be edited like adapters.json.
/// API keys are not in the file; they're in the Keychain.
@MainActor
final class ReverseEngineStore: ObservableObject {
    static let shared = ReverseEngineStore()
    @Published private(set) var engines: [ReverseEngine] = []

    var file: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("reverse_search.json")
    }

    private init() { load() }

    func load() {
        if let data = try? Data(contentsOf: file),
           let list = try? JSONDecoder().decode([ReverseEngine].self, from: data) {
            engines = list
        } else {
            engines = [.demo(port: MockServer.defaultPort)]
            save()
        }
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(engines) { try? data.write(to: file, options: .atomic) }
    }

    func upsert(_ e: ReverseEngine) {
        if let i = engines.firstIndex(where: { $0.id == e.id }) { engines[i] = e } else { engines.append(e) }
        save()
    }

    func delete(_ id: String) {
        engines.removeAll { $0.id == id }
        try? Keychain.delete(service: "reverse-search", account: id)
        save()
    }

    /// Replaces every engine from JSON text (the "Edit as JSON" screen). Throws a readable error.
    func replace(json: String) throws {
        let list = try JSONDecoder().decode([ReverseEngine].self, from: Data(json.utf8))
        let ids = list.map(\.id)
        guard Set(ids).count == ids.count else { throw AppError.message("Two engines have the same id.") }
        engines = list
        save()
    }

    var json: String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? enc.encode(engines)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    }

    func apiKey(for id: String) -> String {
        (try? Keychain.get(service: "reverse-search", account: id)).flatMap { $0 }.map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    func setAPIKey(_ key: String, for id: String) {
        if key.isEmpty { try? Keychain.delete(service: "reverse-search", account: id) }
        else { try? Keychain.set(Data(key.utf8), service: "reverse-search", account: id) }
    }
}

enum ReverseSearch {
    /// Runs one engine for a post's picture.
    static func run(_ engine: ReverseEngine, post: Post) async throws -> [ReverseMatch] {
        let key = await ReverseEngineStore.shared.apiKey(for: engine.id)
        // The demo engine follows the demo server if it had to move to another port.
        let template = engine.requestURL.replacingOccurrences(of: "127.0.0.1:\(MockServer.defaultPort)", with: "127.0.0.1:\(MockServer.shared.port)")
        let picture = post.mediaType == .video ? post.thumbnailURL : (post.sampleURL ?? post.mediaURL)
        let pictureIsLocal = ["127.0.0.1", "localhost"].contains(picture.host ?? "") || picture.isFileURL
        let upload = engine.mode == "upload" || pictureIsLocal
        let encodedPicture = picture.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        let address = template
            .replacingOccurrences(of: "{api_key}", with: key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
            .replacingOccurrences(of: "{url}", with: encodedPicture)
        guard let url = URL(string: address), url.scheme?.hasPrefix("http") == true else {
            throw AppError.message("The engine's request address isn't a valid http(s) address.")
        }
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if upload {
            guard let field = engine.uploadField?.nonEmpty else {
                throw AppError.message("This picture is only on this phone, so it has to be uploaded, but the engine has no upload field name.")
            }
            let data = try await ImagePipeline.shared.data(for: picture)
            let boundary = "MD-\(UUID().uuidString)"
            var body = Data()
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(field)\"; filename=\"image.\(picture.pathExtension.nonEmpty ?? "jpg")\"\r\nContent-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
            body.append(data)
            body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
            req.httpMethod = "POST"
            req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        let http = response as? HTTPURLResponse
        let type = http?.value(forHTTPHeaderField: "Content-Type")
        guard let status = http?.statusCode, (200..<300).contains(status) else {
            let code = http?.statusCode ?? 0
            throw AppError.http(status: code, url: url, message: ErrorParser.describe(status: code, data: data, contentType: type))
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            throw AppError.message(ErrorParser.message(from: data, contentType: type) ?? "The engine didn't answer with JSON.")
        }
        guard let list = DottedPath.evaluate(engine.resultsPath, in: json) as? [Any] else {
            throw AppError.message(ErrorParser.message(from: data, contentType: type)
                                   ?? "No list of matches at '\(engine.resultsPath)' in the engine's answer.")
        }
        let minimum = engine.minSimilarity ?? 0
        return list.compactMap { node -> ReverseMatch? in
            let sim = engine.similarityPath.flatMap { DottedPath.string($0, in: node) }.flatMap { Double($0.replacingOccurrences(of: "%", with: "")) }
            if let s = sim, s < minimum { return nil }
            func link(_ p: String?) -> URL? {
                p.flatMap { DottedPath.string($0, in: node) }.flatMap { URL(string: $0) }.flatMap { $0.scheme?.hasPrefix("http") == true ? $0 : nil }
            }
            return ReverseMatch(similarity: sim, thumbnail: link(engine.thumbnailPath), source: link(engine.sourceURLPath),
                                title: engine.titlePath.flatMap { DottedPath.string($0, in: node) })
        }
        .sorted { ($0.similarity ?? 0) > ($1.similarity ?? 0) }
    }
}

/// Picks an engine (if there are several), runs it and lists the matches.
struct ReverseSearchSheet: View {
    let post: Post
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = ReverseEngineStore.shared
    @State private var engine: ReverseEngine?
    @State private var matches: [ReverseMatch]?
    @State private var error: String?
    @State private var running = false

    var enabled: [ReverseEngine] { store.engines.filter(\.enabled) }

    var body: some View {
        NavigationView {
            List {
                if enabled.isEmpty {
                    Text("No reverse search engines are switched on. Add one in Settings › Reverse Search.")
                        .foregroundColor(.secondary)
                } else if enabled.count > 1 {
                    Section("Engine") {
                        ForEach(enabled) { e in
                            Button { Task { await run(e) } } label: {
                                HStack { Text(e.name).foregroundColor(.primary); Spacer(); if engine?.id == e.id { Image(systemName: "checkmark") } }
                            }
                        }
                    }
                }
                if running {
                    HStack { ProgressView(); Text("Searching \(engine?.name ?? "")…").foregroundColor(.secondary) }
                }
                if let e = error {
                    Section { Label(e, systemImage: "exclamationmark.triangle").foregroundColor(.red) }
                }
                if let m = matches {
                    Section {
                        if m.isEmpty { Text("No matches.").foregroundColor(.secondary) }
                        ForEach(m) { match in MatchRow(match: match) }
                    } header: { Text("\(m.count) match\(m.count == 1 ? "" : "es")") } footer: {
                        Text("Tap a match to open its page. If the page is on one of your sites, MediaDeck opens it there.")
                    }
                }
            }
            .navigationTitle("Reverse Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { if enabled.count == 1, matches == nil { await run(enabled[0]) } }
        }
    }

    func run(_ e: ReverseEngine) async {
        engine = e; running = true; error = nil; matches = nil
        defer { running = false }
        do { matches = try await ReverseSearch.run(e, post: post) }
        catch { self.error = error.localizedDescription }
    }
}

struct MatchRow: View {
    let match: ReverseMatch

    var body: some View {
        Button {
            guard let s = match.source else { return }
            if !LinkRouter.open(s) { UIApplication.shared.open(s) }
        } label: {
            HStack(spacing: 12) {
                Group {
                    if let t = match.thumbnail {
                        CachedAsyncImage(url: t, maxPixel: 200)
                    } else {
                        Color.gray.opacity(0.2).overlay(Image(systemName: "photo").foregroundColor(.secondary))
                    }
                }
                .frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 3) {
                    if let s = match.similarity {
                        Text(String(format: "%.1f%% similar", s)).font(.headline)
                            .foregroundColor(s >= 85 ? .green : (s >= 60 ? .orange : .secondary))
                    }
                    if let t = match.title?.nonEmpty { Text(t).font(.subheadline).foregroundColor(.primary).lineLimit(2) }
                    Text(match.source?.host ?? "No link").font(.caption).foregroundColor(.secondary)
                }
                Spacer()
            }
        }
        .contextMenu {
            if let s = match.source {
                Button { UIPasteboard.general.string = s.absoluteString; ToastCenter.shared.show("Link copied") } label: { Label("Copy Link", systemImage: "doc.on.doc") }
                Button { UIApplication.shared.open(s) } label: { Label("Open in Browser", systemImage: "safari") }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Settings › Reverse Search: engines, their API keys, and the JSON behind them.
struct ReverseEnginesView: View {
    @ObservedObject private var store = ReverseEngineStore.shared
    @State private var editing: ReverseEngine?
    @State private var showJSON = false

    var body: some View {
        List {
            Section {
                ForEach(store.engines) { e in
                    Button { editing = e } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(e.name).foregroundColor(.primary)
                                Text(e.mode == "upload" ? "Uploads the picture" : "Sends the picture's address").font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            if !e.enabled { Text("Off").foregroundColor(.secondary) }
                        }
                    }
                }
                .onDelete { idx in idx.map { store.engines[$0].id }.forEach(store.delete) }
                Button { editing = ReverseEngine(id: "engine-\(Int(Date().timeIntervalSince1970))", name: "New Engine", requestURL: "https://", resultsPath: "results") } label: {
                    Label("Add Engine", systemImage: "plus")
                }
            } footer: {
                Text("A reverse search engine finds where a picture comes from. Like a site adapter, you describe its address and where the matches are in its JSON answer. Use it from the viewer's ⋯ menu.")
            }
            Section {
                Button { showJSON = true } label: { Label("Edit all as JSON", systemImage: "curlybraces") }
                Button {
                    store.upsert(.demo(port: MockServer.defaultPort))
                    ToastCenter.shared.show("Demo engine restored", style: .success)
                } label: { Label("Restore the demo engine", systemImage: "arrow.counterclockwise") }
            } footer: {
                Text("The engines are also in Files › On My iPhone › MediaDeck › reverse_search.json. API keys are kept in the Keychain, not in that file.")
            }
        }
        .navigationTitle("Reverse Search")
        .sheet(item: $editing) { ReverseEngineEditor(engine: $0) }
        .sheet(isPresented: $showJSON) { ReverseJSONEditor() }
    }
}

struct ReverseEngineEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var engine: ReverseEngine
    @State private var apiKey = ""
    @State private var keyPage: AccountView.WebPageRequest?

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("Name", text: $engine.name)
                    Toggle("Switched on", isOn: $engine.enabled)
                    Picker("Send", selection: $engine.mode) {
                        Text("The picture's address").tag("url")
                        Text("The picture file (upload)").tag("upload")
                    }
                }
                Section {
                    field("Request address", $engine.requestURL, "https://…?url={url}&api_key={api_key}")
                    field("Upload field name", opt(\.uploadField), "file")
                } header: { Text("Request") } footer: {
                    Text("{url} becomes the picture's address and {api_key} your key. Pictures that are only on this phone (or the demo server) are always uploaded.")
                }
                Section {
                    SecureField("API key (optional)", text: $apiKey).textInputAutocapitalization(.never).disableAutocorrection(true)
                    field("API key page", opt(\.apiKeyPageURL), "https://…")
                    if let s = engine.apiKeyPageURL?.nonEmpty, let u = URL(string: s) {
                        Button("Open my API key page") { keyPage = AccountView.WebPageRequest(url: u) }
                    }
                } header: { Text("Key") }
                Section {
                    field("Matches list", $engine.resultsPath, "results")
                    field("Similarity", opt(\.similarityPath), "header.similarity")
                    field("Thumbnail", opt(\.thumbnailPath), "header.thumbnail")
                    field("Source link", opt(\.sourceURLPath), "data.urls[0]")
                    field("Title", opt(\.titlePath), "data.title")
                    HStack {
                        Text("Hide matches below")
                        Spacer()
                        TextField("0", value: Binding(get: { engine.minSimilarity ?? 0 }, set: { engine.minSimilarity = $0 }), format: .number)
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 60)
                        Text("%")
                    }
                } header: { Text("Answer") } footer: {
                    Text("Paths work like in adapters: dots between keys, [0] for the first item of a list. The match paths are inside one match.")
                }
            }
            .keyboardDoneButton()
            .navigationTitle(engine.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        ReverseEngineStore.shared.upsert(engine)
                        ReverseEngineStore.shared.setAPIKey(apiKey, for: engine.id)
                        dismiss()
                    }
                    .disabled(engine.name.isEmpty || engine.resultsPath.isEmpty)
                }
            }
            .onAppear { apiKey = ReverseEngineStore.shared.apiKey(for: engine.id) }
            .sheet(item: $keyPage) { ThemedWebPage(url: $0.url, prefillUsername: "") }
        }
    }

    func opt(_ kp: WritableKeyPath<ReverseEngine, String?>) -> Binding<String> {
        Binding(get: { engine[keyPath: kp] ?? "" }, set: { engine[keyPath: kp] = $0.isEmpty ? nil : $0 })
    }

    func field(_ title: String, _ b: Binding<String>, _ placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundColor(.secondary)
            TextField(placeholder, text: b)
                .font(.body.monospaced()).textInputAutocapitalization(.never).disableAutocorrection(true)
        }
    }
}

struct ReverseJSONEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ReverseEngineStore.shared.json
    @State private var error: String?

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if let e = error {
                    Text(e).font(.footnote).foregroundColor(.red).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                }
                TextEditor(text: $text)
                    .font(.system(.footnote, design: .monospaced))
                    .textInputAutocapitalization(.never).disableAutocorrection(true)
                    .padding(.horizontal, 6)
            }
            .navigationTitle("Engines JSON")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do { try ReverseEngineStore.shared.replace(json: text); dismiss() }
                        catch let e as DecodingError { error = "Not saved: \(Self.describe(e))" }
                        catch { self.error = "Not saved: \(error.localizedDescription)" }
                    }
                }
            }
        }
    }

    static func describe(_ e: DecodingError) -> String {
        switch e {
        case .keyNotFound(let k, _): return "a required field \"\(k.stringValue)\" is missing."
        case .typeMismatch(_, let c), .valueNotFound(_, let c): return "a field has the wrong kind of value (\(c.codingPath.map(\.stringValue).joined(separator: ".")))."
        case .dataCorrupted: return "this isn't valid JSON (check commas and quotes)."
        @unknown default: return "the JSON couldn't be read."
        }
    }
}
