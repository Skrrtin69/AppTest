import SwiftUI

/// Hidden tools: Settings › About › tap Version 5 times.
struct DebugConsoleView: View {
    @ObservedObject private var log = DebugLog.shared
    @State private var filter = ""
    @State private var watchResult: String?

    var shown: [DebugLog.Line] {
        let f = filter.lowercased()
        return log.lines.reversed().filter { f.isEmpty || $0.category.lowercased().contains(f) || $0.text.lowercased().contains(f) }
    }

    static let time: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()

    var body: some View {
        List {
            Section("Actions") {
                Button("Check watched searches now") {
                    Task {
                        let n = await SearchWatch.shared.check()
                        watchResult = "\(n) new post\(n == 1 ? "" : "s")"
                    }
                }
                .accessibilityIdentifier("debugRunWatch")
                if let w = watchResult { Text(w).foregroundColor(.secondary) }
                Button("Forget smart thumbnail crops") { SmartCrop.clear(); ToastCenter.shared.show("Smart crops cleared") }
                Button("Copy log") { UIPasteboard.general.string = log.text; ToastCenter.shared.show("Log copied") }
                Button("Clear log", role: .destructive) { log.clear() }
            }
            Section("Info") {
                row("Demo server", MockServer.shared.isRunning ? "127.0.0.1:\(MockServer.shared.port)" : "stopped")
                row("Adapters", "\(AdapterRegistry.shared.configs.count) (\(AdapterRegistry.shared.enabledConfigs.count) on)")
                row("Shared folder", AppGroup.container == nil ? "unavailable" : "available")
                row("Decoy mode", LockManager.shared.decoyActive ? "on" : "off")
            }
            Section {
                TextField("Filter (e.g. HTTP, Watch, OCR)", text: $filter)
                    .textInputAutocapitalization(.never).disableAutocorrection(true)
                if shown.isEmpty { Text("Nothing logged yet.").foregroundColor(.secondary) }
                ForEach(shown) { l in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(Self.time.string(from: l.date)) · \(l.category)").font(.caption2).foregroundColor(.secondary)
                        Text(l.text).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            } header: { Text("Log (newest first, \(log.lines.count) lines)") } footer: {
                Text("Keys, tokens and passwords in addresses are shown as •••.")
            }
        }
        .navigationTitle("Debug Console")
    }

    func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k); Spacer(); Text(v).foregroundColor(.secondary) }
    }
}
