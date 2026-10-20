import SwiftUI
import UIKit

/// A user-made color theme. Colors are stored as hex so they can also be written into the
/// CSS injected into themed web pages.
struct CustomTheme: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var name: String
    var background: String
    var surface: String
    var text: String
    var accent: String
    /// Whether the system UI (keyboards, menus, status bar) should be dark.
    var isDark: Bool

    static let starter = CustomTheme(name: "My Theme", background: "#101826", surface: "#1A2638",
                                     text: "#F2F5FA", accent: "#FF9F0A", isDark: true)
}

/// Saved custom themes and which one is active.
final class CustomThemeStore: ObservableObject {
    static let shared = CustomThemeStore()
    private let listKey = "customThemes", activeKey = "activeCustomTheme"

    @Published private(set) var themes: [CustomTheme] = []
    @Published var activeID: String? { didSet { UserDefaults.standard.set(activeID, forKey: activeKey); Theme.apply(AppSettings.shared.theme) } }

    private init() {
        if let data = UserDefaults.standard.data(forKey: listKey),
           let list = try? JSONDecoder().decode([CustomTheme].self, from: data) { themes = list }
        activeID = UserDefaults.standard.string(forKey: activeKey)
    }

    var active: CustomTheme? { themes.first { $0.id == activeID } ?? themes.first }

    func save(_ t: CustomTheme) {
        if let i = themes.firstIndex(where: { $0.id == t.id }) { themes[i] = t } else { themes.append(t) }
        persist()
        if activeID == t.id { Theme.apply(AppSettings.shared.theme) }
    }

    func delete(_ id: String) {
        themes.removeAll { $0.id == id }
        if activeID == id { activeID = themes.first?.id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(themes) { UserDefaults.standard.set(data, forKey: listKey) }
        objectWillChange.send()
    }
}

extension Color {
    init(hex: String) {
        self.init(UIColor(hex: hex))
    }

    /// "#RRGGBB" for storage and CSS.
    var hexString: String { UIColor(self).hexString }
}

extension UIColor {
    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self.init(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        func c(_ x: CGFloat) -> Int { Int((min(1, max(0, x)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", c(r), c(g), c(b))
    }
}

/// Theme list and editor (Settings › Appearance › Themes).
struct ThemesView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var store = CustomThemeStore.shared
    @State private var editing: CustomTheme?

    var body: some View {
        List {
            Section("Built-in") {
                ForEach(ThemeMode.allCases.filter { $0 != .custom }) { mode in
                    Button { settings.theme = mode } label: {
                        HStack { Text(mode.label).foregroundColor(.primary); Spacer(); if settings.theme == mode { Image(systemName: "checkmark") } }
                    }
                }
            }
            Section {
                ForEach(store.themes) { t in
                    HStack {
                        Button {
                            store.activeID = t.id
                            settings.theme = .custom
                        } label: {
                            HStack(spacing: 10) {
                                ThemeSwatch(theme: t)
                                Text(t.name).foregroundColor(.primary)
                                Spacer()
                                if settings.theme == .custom && store.active?.id == t.id { Image(systemName: "checkmark") }
                            }
                        }
                        Button("Edit") { editing = t }.buttonStyle(.borderless)
                    }
                    .accessibilityElement(children: .contain)
                }
                .onDelete { idx in idx.map { store.themes[$0].id }.forEach(store.delete) }
                Button { editing = CustomTheme.starter } label: { Label("New Theme", systemImage: "paintpalette") }
                    .accessibilityIdentifier("newTheme")
            } header: { Text("My themes") } footer: {
                Text("Custom themes color the whole app, and the site pages MediaDeck opens for logging in.")
            }
        }
        .navigationTitle("Themes")
        .sheet(item: $editing) { t in ThemeEditor(theme: t) }
    }
}

struct ThemeSwatch: View {
    let theme: CustomTheme
    var body: some View {
        HStack(spacing: 0) {
            Color(hex: theme.background); Color(hex: theme.surface); Color(hex: theme.accent)
        }
        .frame(width: 42, height: 22)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.gray.opacity(0.4)))
    }
}

struct ThemeEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var theme: CustomTheme

    var body: some View {
        NavigationView {
            Form {
                TextField("Name", text: $theme.name).accessibilityIdentifier("themeName")
                Toggle("Dark base (keyboards, menus)", isOn: $theme.isDark)
                Section("Colors") {
                    picker("Background", \.background)
                    picker("Surface (cards, bars)", \.surface)
                    picker("Text", \.text)
                    picker("Accent (buttons, links)", \.accent)
                }
                Section("Preview") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Sample title").font(.headline).foregroundColor(Color(hex: theme.text))
                        Text("A link-colored button").foregroundColor(Color(hex: theme.accent))
                        RoundedRectangle(cornerRadius: 8).fill(Color(hex: theme.surface)).frame(height: 30)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(hex: theme.background))
                }
            }
            .keyboardDoneButton()
            .navigationTitle("Edit Theme")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        CustomThemeStore.shared.save(theme)
                        CustomThemeStore.shared.activeID = theme.id
                        AppSettings.shared.theme = .custom
                        dismiss()
                    }
                    .accessibilityIdentifier("saveTheme")
                }
            }
        }
    }

    func picker(_ title: String, _ kp: WritableKeyPath<CustomTheme, String>) -> some View {
        ColorPicker(title, selection: Binding(get: { Color(hex: theme[keyPath: kp]) },
                                              set: { theme[keyPath: kp] = $0.hexString }),
                    supportsOpacity: false)
    }
}
