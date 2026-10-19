import Foundation

/// Remembers Auto-Configure's guesses for each saved adapter, so the adapter form can show
/// confidence dots and Browse can badge sites that still have low-confidence fields.
/// A guess stops counting once the field's value differs from what was guessed.
final class AdapterReviewStore: ObservableObject {
    static let shared = AdapterReviewStore()
    private let key = "autoConfigGuesses"
    @Published private(set) var all: [String: [String: FieldGuess]] = [:]

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: [String: FieldGuess]].self, from: data) {
            all = decoded
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(all) { UserDefaults.standard.set(data, forKey: key) }
    }

    func guesses(for id: String) -> FieldGuesses {
        var out: FieldGuesses = [:]
        for (k, g) in all[id] ?? [:] { if let key = AdapterConfig.CodingKeys(rawValue: k) { out[key] = g } }
        return out
    }

    func set(_ guesses: FieldGuesses, for id: String) {
        all[id] = Dictionary(uniqueKeysWithValues: guesses.map { ($0.key.rawValue, $0.value) })
        persist()
    }

    func clear(_ id: String) {
        all[id] = nil
        persist()
    }

    /// Low-confidence fields the user hasn't changed yet, in form order.
    func pendingLowFields(for config: AdapterConfig) -> [AdapterConfig.CodingKeys] {
        let g = guesses(for: config.id)
        return AdapterConfig.CodingKeys.allCases.filter { k in
            guard let guess = g[k], guess.level == .low else { return false }
            return config.jsonValue(for: k) == guess.value
        }
    }
}
