import Foundation

/// Post counts as people read them, and numeric tag categories as names.
enum TagCount {
    private static let formatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    static func format(_ n: Int) -> String { formatter.string(from: NSNumber(value: n)) ?? String(n) }

    /// Many sites number their categories (0 general, 1 artist, 3 copyright, 4 character, 5 meta).
    static func categoryName(_ raw: String?) -> String? {
        guard let r = raw?.nonEmpty else { return nil }
        switch r {
        case "0": return "general"
        case "1": return "artist"
        case "3": return "copyright"
        case "4": return "character"
        case "5": return "meta"
        default: return Int(r) == nil ? r : nil
        }
    }
}
