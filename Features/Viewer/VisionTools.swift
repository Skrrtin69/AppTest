import SwiftUI
import UIKit
import Vision

/// Vision work shared by text recognition and duplicate finding: one serial utility queue
/// (outside Swift's task pool, see Phase 16), preferBackgroundProcessing, cached results.
enum VisionWork {
    static let queue = DispatchQueue(label: "vision.work", qos: .utility)

    static func run<T>(_ body: @escaping () -> T) async -> T {
        await withCheckedContinuation { cont in queue.async { cont.resume(returning: body()) } }
    }
}

// MARK: - Text in pictures (OCR)

enum TextReader {
    private static let cache = NSCache<NSString, NSArray>()

    /// Lines of text found in the picture, top to bottom.
    static func read(_ post: Post) async throws -> [String] {
        let key = post.mediaURL.absoluteString as NSString
        if let hit = cache.object(forKey: key) as? [String] { return hit }
        let client = AdapterRegistry.shared.adapter(for: post.siteID)?.client
        let img = try await ImagePipeline.shared.image(for: post.mediaURL, maxPixel: 2400, animate: false, client: client)
        guard let cg = img.cgImage else { return [] }
        let lines: [String] = await VisionWork.run {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.preferBackgroundProcessing = true
            let handler = VNImageRequestHandler(cgImage: cg, options: [:])
            guard (try? handler.perform([request])) != nil else { return [] }
            let obs = (request.results ?? []).sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
            return obs.compactMap { $0.topCandidates(1).first?.string }
        }
        cache.setObject(lines as NSArray, forKey: key)
        DebugLog.log("OCR", "\(lines.count) line(s) in \(post.siteID):\(post.id)")
        return lines
    }
}

struct TextInPictureSection: View {
    let post: Post
    @State private var lines: [String]?
    @State private var reading = false
    @State private var error: String?

    var body: some View {
        Section {
            if let l = lines {
                if l.isEmpty {
                    Text("No text found in this picture.").foregroundColor(.secondary)
                } else {
                    Text(l.joined(separator: "\n")).textSelection(.enabled).font(.callout)
                        .accessibilityIdentifier("ocrText")
                    Button {
                        UIPasteboard.general.string = l.joined(separator: "\n")
                        ToastCenter.shared.show("Text copied")
                    } label: { Label("Copy Text", systemImage: "doc.on.doc") }
                }
            } else if reading {
                HStack { ProgressView(); Text("Reading…").foregroundColor(.secondary) }
            } else {
                Button { Task { await read() } } label: { Label("Find Text in Picture", systemImage: "text.viewfinder") }
                    .accessibilityIdentifier("findText")
                if let e = error { Text(e).font(.footnote).foregroundColor(.red) }
            }
        } header: { Text("Text in picture") } footer: {
            Text("Read on this phone; nothing is uploaded.")
        }
    }

    func read() async {
        reading = true
        defer { reading = false }
        do { lines = try await TextReader.read(post) } catch { self.error = error.localizedDescription }
    }
}

// MARK: - Duplicate favorites (feature prints)

enum DuplicateFinder {
    private static var prints: [String: VNFeaturePrintObservation] = [:]
    private static let lock = NSLock()

    static func featurePrint(_ post: Post) async -> VNFeaturePrintObservation? {
        lock.lock(); let known = prints[post.key]; lock.unlock()
        if let k = known { return k }
        let client = AdapterRegistry.shared.adapter(for: post.siteID)?.client
        guard let img = try? await ImagePipeline.shared.image(for: post.thumbnailURL, maxPixel: 360, animate: false, client: client),
              let cg = img.cgImage else { return nil }
        let fp: VNFeaturePrintObservation? = await VisionWork.run {
            let request = VNGenerateImageFeaturePrintRequest()
            request.preferBackgroundProcessing = true
            let handler = VNImageRequestHandler(cgImage: cg, options: [:])
            guard (try? handler.perform([request])) != nil else { return nil }
            return request.results?.first as? VNFeaturePrintObservation
        }
        if let f = fp { lock.lock(); prints[post.key] = f; lock.unlock() }
        return fp
    }

    /// Groups of favorites that look alike (closer than `threshold` × the median distance), biggest first.
    static func groups(_ posts: [Post], threshold: Float, progress: @escaping (Int) -> Void) async -> [[Post]] {
        var items: [(Post, VNFeaturePrintObservation)] = []
        for (i, p) in posts.enumerated() {
            if Task.isCancelled { return [] }
            if let f = await featurePrint(p) { items.append((p, f)) }
            await MainActor.run { progress(i + 1) }
        }
        // All pair distances. Their scale differs between Vision versions (iOS 16 vs 17), so
        // "close" is measured against the typical (median) distance between these favorites.
        var pairs: [(Int, Int, Float)] = []
        for i in items.indices {
            for j in items.indices where j > i {
                var d: Float = .greatestFiniteMagnitude
                if (try? items[i].1.computeDistance(&d, to: items[j].1)) != nil { pairs.append((i, j, d)) }
            }
        }
        let sorted = pairs.map(\.2).sorted()
        let median = sorted.isEmpty ? 1 : sorted[sorted.count / 2]
        let limit = median * threshold
        DebugLog.log("Dupes", "\(items.count) prints, \(pairs.count) pairs, min \(sorted.first ?? 0), median \(median), limit \(limit)")
        // Union-find over the close pairs.
        var parent = Array(items.indices)
        func root(_ i: Int) -> Int { var i = i; while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }; return i }
        for (i, j, d) in pairs where d < limit { parent[root(j)] = root(i) }
        var buckets: [Int: [Post]] = [:]
        for i in items.indices { buckets[root(i), default: []].append(items[i].0) }
        return buckets.values.filter { $0.count > 1 }.sorted { $0.count > $1.count }
    }
}

struct DuplicatesSheet: View {
    let posts: [Post]
    @Environment(\.dismiss) private var dismiss
    @State private var groups: [[Post]]?
    @State private var done = 0
    @State private var strictness = 1   // 0 loose, 1 normal, 2 strict

    /// Fraction of the typical distance between favorites.
    var threshold: Float { [0.5, 0.33, 0.18][strictness] }

    var body: some View {
        NavigationView {
            // A plain scroll view, not a List: several buttons inside one List row misfire.
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("Match", selection: $strictness) {
                        Text("Loose").tag(0); Text("Normal").tag(1); Text("Strict").tag(2)
                    }
                    .pickerStyle(.segmented)
                    Text("Compares how the pictures look, on this phone. Loose finds more, including only-similar pictures.")
                        .font(.footnote).foregroundColor(.secondary)
                    if let g = groups {
                        if g.isEmpty { Text("No look-alike favorites found.").foregroundColor(.secondary) }
                        ForEach(g.indices, id: \.self) { i in
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Group \(i + 1) · \(g[i].count) look alike").font(.subheadline.weight(.semibold))
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 10) {
                                        ForEach(g[i], id: \.key) { p in
                                            VStack(spacing: 4) {
                                                CachedAsyncImage(url: p.thumbnailURL, maxPixel: 300)
                                                    .frame(width: 96, height: 96).clipShape(RoundedRectangle(cornerRadius: 6))
                                                Text(AdapterRegistry.shared.displayName(for: p.siteID)).font(.caption2).lineLimit(1)
                                                Button("Unfavorite") { LibraryStore.shared.toggleFavorite(p); remove(p) }
                                                    .font(.caption).buttonStyle(.bordered)
                                                    .accessibilityLabel("Unfavorite \(p.id)")
                                            }
                                            .frame(width: 100)
                                        }
                                    }
                                }
                            }
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.12)))
                        }
                    } else {
                        HStack { ProgressView(); Text("Comparing \(done) of \(posts.count)…").foregroundColor(.secondary) }
                    }
                }
                .padding()
            }
            .navigationTitle("Look-alike Favorites")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task(id: strictness) {
                groups = nil; done = 0
                groups = await DuplicateFinder.groups(posts, threshold: threshold) { done = $0 }
            }
        }
    }

    func remove(_ p: Post) {
        groups = groups?.map { $0.filter { $0.key != p.key } }.filter { $0.count > 1 }
    }
}
