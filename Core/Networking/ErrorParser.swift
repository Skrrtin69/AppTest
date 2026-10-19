import Foundation

/// Extracts the server's own explanation from an error response, whatever its shape.
/// Nothing here knows any specific status code: the text comes from the body when there is
/// one, and falls back to "HTTP <status>".
enum ErrorParser {
    /// Keys that commonly hold a human-readable error, in preference order.
    static let messageKeys = ["message", "error_description", "detail", "description", "error",
                              "errors", "msg", "reason", "title", "status_message"]

    static func message(from data: Data, contentType: String?) -> String? {
        guard !data.isEmpty else { return nil }
        if let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
           let text = extract(json, depth: 0) {
            return clean(text)
        }
        let body = String(decoding: data.prefix(4000), as: UTF8.self)
        let type = (contentType ?? "").lowercased()
        if type.contains("html") || body.trimmingCharacters(in: .whitespaces).hasPrefix("<") {
            return htmlMessage(body)
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : clean(trimmed)
    }

    /// Full user-facing line: the server's words, or "HTTP 429" when it gave none.
    static func describe(status: Int, data: Data, contentType: String?) -> String {
        message(from: data, contentType: contentType) ?? "HTTP \(status)"
    }

    private static func extract(_ v: Any, depth: Int) -> String? {
        guard depth < 4 else { return nil }
        switch v {
        case let s as String:
            return s.nonEmpty
        case let d as [String: Any]:
            for k in messageKeys {
                if let match = d.first(where: { $0.key.lowercased() == k }), let text = extract(match.value, depth: depth + 1) {
                    return text
                }
            }
            return nil
        case let a as [Any]:
            // e.g. "errors": [{"message": "..."}, ...] or ["first problem", "second"]
            let parts = a.prefix(3).compactMap { extract($0, depth: depth + 1) }
            return parts.isEmpty ? nil : parts.joined(separator: "; ")
        default:
            return nil
        }
    }

    private static func htmlMessage(_ html: String) -> String? {
        for tag in ["title", "h1", "h2", "p"] {
            if let r = html.range(of: "<\(tag)[^>]*>(.*?)</\(tag)>", options: [.regularExpression, .caseInsensitive]) {
                let inner = html[r].replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                if let text = clean(inner).nonEmpty { return text }
            }
        }
        return nil
    }

    private static func clean(_ s: String) -> String {
        let collapsed = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.count > 300 ? String(collapsed.prefix(300)) + "…" : collapsed
    }
}
