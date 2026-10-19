import Foundation

/// Turns search-bar text into tags. Words are separated by spaces; "quoted phrases" are a
/// single tag (their spaces are later replaced by the adapter's tagSpaceReplacement);
/// a leading "-" (also before a quote) marks an excluded tag.
enum TagQuery {
    static func parse(_ text: String) -> [String] {
        var tags: [String] = []
        var current = ""
        var inQuotes = false
        for ch in text {
            if ch == "\"" || ch == "\u{201C}" || ch == "\u{201D}" {
                inQuotes.toggle()
                continue
            }
            if ch.isWhitespace && !inQuotes {
                flush(&current, into: &tags)
            } else {
                current.append(ch)
            }
        }
        flush(&current, into: &tags)
        return tags
    }

    private static func flush(_ current: inout String, into tags: inout [String]) {
        let t = current.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty && t != "-" { tags.append(t) }
        current = ""
    }

    /// Text for one tag in the search bar (quoted when it contains a space).
    static func display(_ tag: String) -> String {
        guard tag.contains(" ") else { return tag }
        if tag.hasPrefix("-") { return "-\"\(tag.dropFirst())\"" }
        return "\"\(tag)\""
    }

    /// The word currently being typed (after the last unquoted space), without a leading "-".
    static func partialToken(_ text: String) -> String {
        guard !text.hasSuffix(" ") else { return "" }
        let last = parse(text).last ?? ""
        return last.hasPrefix("-") ? String(last.dropFirst()) : last
    }

    /// Replaces the word being typed with `suggestion`, keeping a "-" prefix, and adds a space.
    static func applySuggestion(_ suggestion: String, to text: String) -> String {
        var tags = parse(text)
        let excluded = tags.last?.hasPrefix("-") ?? false
        if !text.hasSuffix(" "), !tags.isEmpty { tags.removeLast() }
        tags.append(excluded ? "-" + suggestion : suggestion)
        return tags.map(display).joined(separator: " ") + " "
    }
}
