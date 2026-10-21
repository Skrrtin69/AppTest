import SwiftUI
import PhotosUI

/// Reverse search for a picture from the Photo Library (Settings › Tools): pick a photo,
/// choose which of your sites to look for, and see the matches in a grid. A match on one of
/// your sites opens that post in the app.
struct PhotoReverseSearchView: View {
    @ObservedObject private var store = ReverseEngineStore.shared
    @ObservedObject private var registry = AdapterRegistry.shared
    @State private var image: UIImage?
    @State private var showPicker = false
    @State private var showSites = false
    @State private var engineID: String?
    /// Adapter IDs to keep matches for; empty with `allSites` on means no filtering.
    @State private var selected: Set<String> = []
    @State private var allSites = true
    @State private var matches: [ReverseMatch]?
    @State private var error: String?
    @State private var running = false
    @State private var opening = false
    @State private var viewer: ViewerRequest?

    var engines: [ReverseEngine] { store.engines.filter(\.enabled) }
    var engine: ReverseEngine? { engines.first { $0.id == engineID } ?? engines.first }
    var sites: [AdapterConfig] { registry.enabledConfigs }

    /// Matches on the chosen sites (all of them with Check All).
    var shown: [ReverseMatch] {
        guard let all = matches else { return [] }
        if allSites { return all }
        return all.filter { m in m.source.flatMap { LinkRouter.site(for: $0)?.id }.map { selected.contains($0) } ?? false }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                pictureCard
                if engines.isEmpty {
                    Label("No reverse search engines are switched on. Add one in Settings › Reverse Search.", systemImage: "exclamationmark.triangle")
                        .foregroundColor(.secondary)
                } else if engines.count > 1 {
                    Picker("Engine", selection: Binding(get: { engine?.id ?? "" }, set: { engineID = $0 })) {
                        ForEach(engines) { Text($0.name).tag($0.id) }
                    }
                    .pickerStyle(.segmented)
                }
                if running {
                    HStack { ProgressView(); Text("Searching \(engine?.name ?? "")…").foregroundColor(.secondary) }
                }
                if let e = error {
                    Label(e, systemImage: "exclamationmark.triangle").foregroundColor(.red)
                }
                if matches != nil { results }
            }
            .padding(16)
        }
        .navigationTitle("Reverse Search Image")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showPicker) {
            PhotoPicker { picked in
                showPicker = false
                guard let picked = picked else { return }
                image = picked
                matches = nil
                error = nil
                // Then choose the sites to check.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { showSites = true }
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showSites) {
            SitePickerSheet(sites: sites, selected: $selected, allSites: $allSites) {
                showSites = false
                Task { await search() }
            }
        }
        .overlay { if opening { ProgressView().padding(24).background(RoundedRectangle(cornerRadius: 12).fill(.thinMaterial)) } }
        .fullScreenCover(item: $viewer) { ViewerView(posts: $0.posts, startIndex: $0.index) }
    }

    var pictureCard: some View {
        HStack(spacing: 14) {
            Group {
                if let img = image {
                    Image(uiImage: img).resizable().scaledToFill()
                } else {
                    Image(systemName: "photo.on.rectangle").font(.largeTitle).foregroundColor(.secondary)
                }
            }
            .frame(width: 96, height: 96)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.15)))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .accessibilityIdentifier("photoReversePreview")
            VStack(alignment: .leading, spacing: 8) {
                Button { showPicker = true } label: {
                    Label(image == nil ? "Choose Photo" : "Choose Another", systemImage: "photo")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("choosePhoto")
                if image != nil {
                    Button { showSites = true } label: {
                        Label(allSites ? "All sites" : "\(selected.count) site\(selected.count == 1 ? "" : "s")", systemImage: "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityIdentifier("chooseSites")
                }
            }
        }
    }

    var results: some View {
        let list = shown
        return VStack(alignment: .leading, spacing: 10) {
            Text(allSites ? "\(list.count) match\(list.count == 1 ? "" : "es")"
                          : "\(list.count) of \(matches?.count ?? 0) matches are on the chosen sites")
                .font(.subheadline.weight(.semibold))
                .accessibilityIdentifier("photoReverseCount")
            if list.isEmpty {
                Text(matches?.isEmpty == true ? "No matches." : "None of the matches are on the chosen sites. Tap the sites button to check more.")
                    .foregroundColor(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
                ForEach(list) { m in
                    MatchCell(match: m)
                        .onTapGesture { Task { await open(m) } }
                        .contextMenu {
                            if let s = m.source {
                                Button { UIApplication.shared.open(s) } label: { Label("Open Source Page", systemImage: "safari") }
                                Button { UIPasteboard.general.url = s } label: { Label("Copy Link", systemImage: "doc.on.doc") }
                            }
                            Button { Task { await MatchOpener.save(m) } } label: { Label("Save", systemImage: "square.and.arrow.down") }
                        }
                }
            }
            Text("Tap a match to view it: a match on one of your sites opens that post in the app. Hold a match for its page and link.")
                .font(.footnote).foregroundColor(.secondary)
        }
    }

    func search() async {
        guard let img = image, let e = engine else { return }
        guard let jpeg = ReverseSearch.uploadJPEG(img) else { error = "Couldn't prepare this photo."; return }
        running = true; error = nil; matches = nil
        defer { running = false }
        do {
            matches = try await ReverseSearch.run(e, jpeg: jpeg)
            DebugLog.log("Reverse", "photo: \(matches?.count ?? 0) matches, \(shown.count) on the chosen sites (\(allSites ? "all" : selected.sorted().joined(separator: ", ")))")
        } catch {
            self.error = error.localizedDescription
        }
    }

    func open(_ m: ReverseMatch) async {
        opening = true
        defer { opening = false }
        if let p = await MatchOpener.post(for: m) { viewer = ViewerRequest(posts: [p], index: 0) }
        else if let s = m.source { await UIApplication.shared.open(s) }
    }
}

/// One match in the grid: its preview, similarity and which of your sites it's on.
private struct MatchCell: View {
    let match: ReverseMatch

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let t = match.thumbnail {
                        CachedAsyncImage(url: t, maxPixel: 300, animate: false)
                    } else {
                        Color.secondary.opacity(0.2).overlay(Image(systemName: "photo").foregroundColor(.secondary))
                    }
                }
                .frame(height: 120)
                .frame(maxWidth: .infinity)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 10))
                if let s = match.similarity {
                    Text(String(format: "%.0f%%", s))
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Capsule().fill(Color.black.opacity(0.65)))
                        .foregroundColor(.white)
                        .padding(5)
                }
            }
            Text(siteName).font(.caption2).foregroundColor(.secondary).lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Match \(match.similarity.map { String(format: "%.0f%%", $0) } ?? ""), \(siteName)")
    }

    var siteName: String {
        guard let s = match.source else { return "No link" }
        return LinkRouter.site(for: s)?.displayName ?? (s.host ?? "Other site")
    }
}

/// Which of your sites to look for matches on.
private struct SitePickerSheet: View {
    let sites: [AdapterConfig]
    @Binding var selected: Set<String>
    @Binding var allSites: Bool
    let onSearch: () -> Void

    var body: some View {
        NavigationView {
            List {
                Section {
                    Toggle("Check All", isOn: Binding(get: { allSites }, set: { on in
                        allSites = on
                        if on { selected = [] }
                    }))
                    .accessibilityIdentifier("checkAllSites")
                } footer: {
                    Text("Check All shows every match. Otherwise only matches that link to the sites you pick are shown.")
                }
                Section("Your sites") {
                    ForEach(sites, id: \.id) { c in
                        Toggle(c.displayName, isOn: Binding(get: { allSites || selected.contains(c.id) }, set: { on in
                            if allSites { allSites = false; selected = [] }
                            if on { selected.insert(c.id) } else { selected.remove(c.id) }
                        }))
                    }
                }
            }
            .navigationTitle("Sites to Check")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Search") { onSearch() }
                        .disabled(!allSites && selected.isEmpty)
                        .accessibilityIdentifier("searchSites")
                }
            }
        }
    }
}

/// The system photo picker (one picture). Works on iOS 15, where SwiftUI's PhotosPicker
/// isn't available.
struct PhotoPicker: UIViewControllerRepresentable {
    let onPick: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ vc: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPick: (UIImage?) -> Void
        init(onPick: @escaping (UIImage?) -> Void) { self.onPick = onPick }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let provider = results.first?.itemProvider, provider.canLoadObject(ofClass: UIImage.self) else {
                onPick(nil)
                return
            }
            provider.loadObject(ofClass: UIImage.self) { object, _ in
                DispatchQueue.main.async { self.onPick(object as? UIImage) }
            }
        }
    }
}
