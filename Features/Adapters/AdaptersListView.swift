import SwiftUI
import UniformTypeIdentifiers

struct EditRequest: Identifiable {
    let id = UUID()
    let config: AdapterConfig
    let isNew: Bool
    /// Field to scroll to when the form opens.
    var focus: AdapterConfig.CodingKeys? = nil
}

/// Sites & Adapters: enable/disable, reorder, add/edit, import/export adapters.json.
struct AdaptersListView: View {
    @ObservedObject private var registry = AdapterRegistry.shared
    @ObservedObject private var auth = AuthManager.shared
    @State private var editing: EditRequest?
    @State private var confirmReset = false

    var body: some View {
        List {
            if let problem = registry.loadProblem {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Your adapters.json has a problem").bold()
                            Text(problem).font(.footnote)
                            Text(registry.usingBundledFallback ? "Using the built-in demo adapters until it's fixed." : "")
                                .font(.footnote).foregroundColor(.secondary)
                        }
                    } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange) }
                    .accessibilityIdentifier("adaptersProblem")
                }
            }
            Section {
                ForEach(registry.configs) { c in
                    HStack(spacing: 12) {
                        Toggle("", isOn: Binding(get: { !registry.disabledIDs.contains(c.id) },
                                                 set: { registry.setEnabled($0, id: c.id) }))
                            .labelsHidden()
                            .accessibilityLabel("Enable \(c.displayName)")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.displayName).font(.body.weight(.medium))
                            Text(c.baseURL.absoluteString).font(.caption2.monospaced()).foregroundColor(.secondary).lineLimit(1)
                            let st = auth.status(for: c)
                            Label(st.label, systemImage: st.isGood ? "checkmark.circle" : "person.crop.circle.badge.exclamationmark")
                                .font(.caption2).foregroundColor(st.isGood ? .green : .orange)
                        }
                        Spacer()
                        Button("Edit") { editing = EditRequest(config: c, isNew: false) }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Edit \(c.displayName)")
                    }
                    .accessibilityElement(children: .contain)
                }
                .onMove { registry.move(fromOffsets: $0, toOffset: $1) }
            } header: { Text("Your adapters") } footer: {
                Text("Switch off to hide a site. Tap Edit (top right) and drag the handles to reorder.")
            }

            Section("Add") {
                NavigationLink(destination: AutoConfigView(mode: .standalone)) {
                    Label("Auto-configure from URL", systemImage: "sparkles")
                }
                .accessibilityIdentifier("autoConfigure")
                Button { editing = EditRequest(config: .blank(), isNew: true) } label: {
                    Label("Add Adapter", systemImage: "plus.circle.fill")
                }
                .accessibilityIdentifier("addAdapter")
                NavigationLink(destination: FieldMapperView()) { Label("Field Mapper", systemImage: "list.bullet.indent") }
                NavigationLink(destination: FieldGuideView()) { Label("Field Guide (what every field means)", systemImage: "book") }
            }

            Section {
                Button { exportFile() } label: { Label("Export adapters.json to Files", systemImage: "square.and.arrow.up") }
                Button { importFile() } label: { Label("Import adapters.json from Files", systemImage: "square.and.arrow.down") }
                Button(role: .destructive) { confirmReset = true } label: { Label("Reset to Built-in Demo Adapters", systemImage: "arrow.counterclockwise") }
            } header: { Text("adapters.json file") } footer: {
                Text("Export saves a copy you can open in any text editor. After editing, Import it back — the app checks it and tells you in plain words if something is wrong.")
            }

            Section("How adapters work") {
                Text(FieldGuide.howItWorks).font(.footnote)
            }
        }
        .navigationTitle("Sites & Adapters")
        .toolbar { EditButton() }
        .sheet(item: $editing) { req in
            NavigationView { AdapterEditorView(config: req.config, isNew: req.isNew, focus: req.focus) }
                // Only Cancel/Save close the editor, so a stray swipe can't lose unsaved changes.
                .interactiveDismissDisabled(true)
        }
        .confirmationDialog("Replace your adapters with the built-in demo ones?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) {
                do { try registry.resetToBundled(); ToastCenter.shared.show("Adapters reset", style: .success) } catch { ToastCenter.shared.error(error) }
            }
        }
    }

    func exportFile() {
        do {
            let url = try registry.exportFileURL()
            Presenter.exportToFiles([url])
        } catch {
            ToastCenter.shared.error(error, prefix: "Export failed")
        }
    }

    func importFile() {
        Presenter.importFile(types: [.json, .plainText, .data]) { url in
            do {
                let data = try Data(contentsOf: url)
                try registry.importFile(data)
                ToastCenter.shared.show("Imported \(registry.configs.count) adapters", style: .success)
            } catch {
                ToastCenter.shared.show(error.localizedDescription, style: .error)
            }
        }
    }
}

/// Every field explained, grouped like the editor.
struct FieldGuideView: View {
    var body: some View {
        List {
            Section { Text(FieldGuide.howItWorks).font(.footnote) }
            ForEach(FieldGuide.sections, id: \.title) { section in
                Section {
                    ForEach(section.fields, id: \.self) { key in
                        let e = FieldGuide.entry(key)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(e.title).bold()
                                if e.required { Text("required").font(.caption2.bold()).foregroundColor(.orange) }
                            }
                            Text("In the file: \"\(key.rawValue)\"").font(.caption.monospaced()).foregroundColor(.secondary)
                            Text(e.help).font(.footnote)
                            if !e.example.isEmpty {
                                Text("Example: \(e.example.replacingOccurrences(of: "\n", with: " · "))").font(.caption.monospaced()).foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } header: { Text(section.title) } footer: { Text(section.intro) }
            }
        }
        .navigationTitle("Field Guide")
    }
}
