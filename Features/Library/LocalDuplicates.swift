import SwiftUI
import ImageIO

/// Settings › Find Duplicates: downloaded pictures that look the same (perceptual hash),
/// grouped; "Delete Lower Quality" keeps the biggest picture of each group.
struct LocalDuplicatesView: View {
    struct Entry: Identifiable {
        let item: DownloadItem
        let pixels: Int
        let bytes: Int
        var id: String { item.id }
    }

    @State private var groups: [[Entry]]?
    @State private var done = 0
    @State private var total = 0
    @State private var confirm = false

    var extras: [String] { (groups ?? []).flatMap { g in g.sorted(by: better).dropFirst().map(\.id) } }

    func better(_ a: Entry, _ b: Entry) -> Bool { a.pixels != b.pixels ? a.pixels > b.pixels : a.bytes > b.bytes }

    var body: some View {
        List {
            if let g = groups {
                Section {
                    Text(g.isEmpty ? "No duplicates among your downloaded pictures." : "\(g.count) group\(g.count == 1 ? "" : "s") · \(extras.count) lower-quality cop\(extras.count == 1 ? "y" : "ies")")
                        .accessibilityIdentifier("dupeSummary")
                    if !extras.isEmpty {
                        Button("Delete Lower Quality (\(extras.count))", role: .destructive) { confirm = true }
                            .accessibilityIdentifier("deleteLowerQuality")
                    }
                } footer: { Text("Pictures are compared by how they look (a small fingerprint), so copies saved at different sizes or from different sites are found. In each group the largest picture is kept.") }
                ForEach(g.indices, id: \.self) { i in
                    Section("Group \(i + 1)") {
                        ForEach(g[i].sorted(by: better)) { e in
                            HStack {
                                if let f = e.item.fileURL { CachedAsyncImage(url: f, maxPixel: 160).frame(width: 50, height: 50).clipShape(RoundedRectangle(cornerRadius: 5)) }
                                VStack(alignment: .leading) {
                                    Text(e.item.filename).lineLimit(1)
                                    Text("\(e.pixels > 0 ? "\(Int(Double(e.pixels).squareRoot()))px-ish · " : "")\(ByteCountFormatter.string(fromByteCount: Int64(e.bytes), countStyle: .file))")
                                        .font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                                Text(e.id == g[i].sorted(by: better).first?.id ? "Keep" : "Extra")
                                    .font(.caption.weight(.bold)).foregroundColor(e.id == g[i].sorted(by: better).first?.id ? .green : .orange)
                            }
                        }
                    }
                }
            } else {
                HStack { ProgressView(); Text("Checking \(done) of \(total)…").foregroundColor(.secondary) }
            }
        }
        .navigationTitle("Find Duplicates")
        .confirmationDialog("Delete \(extras.count) lower-quality cop\(extras.count == 1 ? "y" : "ies")?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                DownloadManager.shared.removeWithUndo(extras)
                groups = []
            }
        }
        .task { await scan() }
    }

    func scan() async {
        let items = DownloadManager.shared.completed.filter {
            guard let f = $0.fileURL else { return false }
            return DownloadPostProcess.imageExts.contains(f.pathExtension.lowercased()) || f.pathExtension.lowercased() == "gif"
        }
        total = items.count
        var hashed: [(Entry, UInt64)] = []
        for (i, item) in items.enumerated() {
            guard let f = item.fileURL else { continue }
            let result: (UInt64?, Int, Int) = await Task.detached(priority: .utility) {
                let h = PerceptualHash.dHash(f)
                var px = 0
                if let s = CGImageSourceCreateWithURL(f as CFURL, nil), let p = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any] {
                    px = ((p[kCGImagePropertyPixelWidth] as? Int) ?? 0) * ((p[kCGImagePropertyPixelHeight] as? Int) ?? 0)
                }
                let b = (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return (h, px, b)
            }.value
            if let h = result.0 { hashed.append((Entry(item: item, pixels: result.1, bytes: result.2), h)) }
            done = i + 1
        }
        // Union-find over pairs at most 6 bits apart.
        var parent = Array(hashed.indices)
        func root(_ i: Int) -> Int { var i = i; while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }; return i }
        for i in hashed.indices { for j in hashed.indices where j > i && PerceptualHash.distance(hashed[i].1, hashed[j].1) <= 6 { parent[root(j)] = root(i) } }
        var buckets: [Int: [Entry]] = [:]
        for i in hashed.indices { buckets[root(i), default: []].append(hashed[i].0) }
        groups = buckets.values.filter { $0.count > 1 }.sorted { $0.count > $1.count }
    }
}

/// Library › select › Rename: new file names from a template.
struct BulkRenameSheet: View {
    let ids: [String]
    @Environment(\.dismiss) private var dismiss
    @State private var template = "{id}_{index}.{ext}"

    var preview: [String] {
        let items = ids.compactMap { id in DownloadManager.shared.items.first { $0.id == id } }
        return items.prefix(5).enumerated().map { i, item in
            let ext = item.fileURL?.pathExtension ?? ""
            return template.replacingOccurrences(of: "{id}", with: item.post.id)
                .replacingOccurrences(of: "{site}", with: item.post.siteID)
                .replacingOccurrences(of: "{index}", with: String(format: "%03d", i + 1))
                .replacingOccurrences(of: "{type}", with: item.post.mediaType.rawValue)
                .replacingOccurrences(of: "{name}", with: item.fileURL?.deletingPathExtension().lastPathComponent ?? "")
                .replacingOccurrences(of: "{ext}", with: ext)
        }
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("Name template", text: $template)
                        .font(.body.monospaced()).textInputAutocapitalization(.never).disableAutocorrection(true)
                        .accessibilityIdentifier("renameTemplate")
                } footer: { Text("Placeholders: {id} {site} {index} (001, 002…) {type} {date} {name} (current name) {ext}. Files stay in their folders; a number is added if a name is taken.") }
                Section("Preview") { ForEach(preview, id: \.self) { Text($0).font(.caption.monospaced()) } }
            }
            .keyboardDoneButton()
            .navigationTitle("Rename \(ids.count) File\(ids.count == 1 ? "" : "s")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Rename") {
                        let n = DownloadManager.shared.rename(ids, template: template)
                        ToastCenter.shared.show("Renamed \(n) file\(n == 1 ? "" : "s")", style: .success)
                        dismiss()
                    }
                    .disabled(template.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("renameApply")
                }
            }
        }
    }
}
