import Foundation

/// Evaluates dotted paths against JSON decoded with JSONSerialization.
///
/// Supported syntax:
///   `a.b.c`   object keys
///   `a[0]`    array index
///   `a[].b`   map over every element of `a`, collect `b` from each (returns an array)
///   `a[*].b`  same as `a[]`
/// An empty path means "the value itself".
enum DottedPath {
    enum Token: Equatable {
        case key(String)
        case index(Int)
        case each
    }

    static func tokenize(_ path: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var i = path.startIndex
        func flushKey() {
            if !current.isEmpty { tokens.append(.key(current)); current = "" }
        }
        while i < path.endIndex {
            let ch = path[i]
            if ch == "." {
                flushKey()
            } else if ch == "[" {
                flushKey()
                guard let close = path[i...].firstIndex(of: "]") else { current.append(ch); i = path.index(after: i); continue }
                let inner = path[path.index(after: i)..<close].trimmingCharacters(in: .whitespaces)
                if inner.isEmpty || inner == "*" {
                    tokens.append(.each)
                } else if let n = Int(inner) {
                    tokens.append(.index(n))
                } else {
                    // a["quoted key"] style
                    tokens.append(.key(inner.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))))
                }
                i = close
            } else {
                current.append(ch)
            }
            i = path.index(after: i)
        }
        flushKey()
        return tokens
    }

    static func evaluate(_ path: String, in json: Any) -> Any? {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return json }
        return evaluate(tokenize(trimmed)[...], in: json)
    }

    private static func evaluate(_ tokens: ArraySlice<Token>, in json: Any) -> Any? {
        guard let first = tokens.first else { return json }
        let rest = tokens.dropFirst()
        switch first {
        case .key(let k):
            guard let dict = json as? [String: Any], let v = dict[k], !(v is NSNull) else { return nil }
            return evaluate(rest, in: v)
        case .index(let n):
            guard let arr = json as? [Any] else { return nil }
            let idx = n < 0 ? arr.count + n : n
            guard arr.indices.contains(idx) else { return nil }
            return evaluate(rest, in: arr[idx])
        case .each:
            guard let arr = json as? [Any] else { return nil }
            return arr.compactMap { evaluate(rest, in: $0) }
        }
    }

    // MARK: - Typed helpers

    static func string(_ path: String, in json: Any) -> String? {
        guard !path.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return stringValue(evaluate(path, in: json))
    }

    static func stringValue(_ v: Any?) -> String? {
        switch v {
        case let s as String: return s
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            return n.stringValue
        case let a as [Any]: return a.compactMap { stringValue($0) }.first
        default: return nil
        }
    }

    /// Strings from an array of strings, an array of objects (using `nameKey`), or a
    /// single space-separated string.
    static func strings(_ path: String, in json: Any, nameKey: String? = nil) -> [String] {
        guard !path.trimmingCharacters(in: .whitespaces).isEmpty, let v = evaluate(path, in: json) else { return [] }
        return flattenStrings(v, nameKey: nameKey)
    }

    private static func flattenStrings(_ v: Any, nameKey: String?) -> [String] {
        switch v {
        case let s as String:
            return s.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        case let n as NSNumber:
            return [n.stringValue]
        case let a as [Any]:
            return a.flatMap { flattenStrings($0, nameKey: nameKey) }
        case let d as [String: Any]:
            let key = (nameKey?.isEmpty == false ? nameKey! : "name")
            if let name = d[key].flatMap({ stringValue($0) }) { return [name] }
            // Some APIs group tags by category: {"general": [...], "artist": [...]}
            return d.values.flatMap { flattenStrings($0, nameKey: nameKey) }
        default:
            return []
        }
    }

    static func bool(_ path: String, in json: Any) -> Bool? {
        guard let v = evaluate(path, in: json) else { return nil }
        switch v {
        case let n as NSNumber: return n.boolValue
        case let s as String: return ["true", "yes", "1"].contains(s.lowercased())
        default: return nil
        }
    }

    // MARK: - Flattening for the Field Mapper

    struct Row: Identifiable {
        let id = UUID()
        let path: String
        let depth: Int
        let kind: String     // "object", "array", "string", "number", "bool", "null"
        let preview: String
        var isContainer: Bool { kind == "object" || kind == "array" }
    }

    /// Lists every path in `json`. Arrays show their first `maxItems` elements individually,
    /// plus an `a[]` row that the "List of results" field can use.
    static func flatten(_ json: Any, maxItems: Int = 3, maxRows: Int = 2000) -> [Row] {
        var rows: [Row] = []
        func walk(_ v: Any, path: String, depth: Int) {
            guard rows.count < maxRows else { return }
            switch v {
            case let d as [String: Any]:
                if !path.isEmpty { rows.append(Row(path: path, depth: depth, kind: "object", preview: "{ \(d.count) fields }")) }
                for k in d.keys.sorted() {
                    walk(d[k]!, path: path.isEmpty ? k : "\(path).\(k)", depth: path.isEmpty ? depth : depth + 1)
                }
            case let a as [Any]:
                rows.append(Row(path: path.isEmpty ? "[]" : path, depth: depth, kind: "array", preview: "[ \(a.count) items ]"))
                for (i, el) in a.prefix(maxItems).enumerated() {
                    walk(el, path: "\(path)[\(i)]", depth: depth + 1)
                }
                if a.count > maxItems {
                    rows.append(Row(path: "\(path)[…]", depth: depth + 1, kind: "null", preview: "… \(a.count - maxItems) more items not shown"))
                }
            case let s as String:
                rows.append(Row(path: path, depth: depth, kind: "string", preview: "\"\(s.prefix(160))\""))
            case let n as NSNumber:
                let isBool = CFGetTypeID(n) == CFBooleanGetTypeID()
                rows.append(Row(path: path, depth: depth, kind: isBool ? "bool" : "number",
                                preview: isBool ? (n.boolValue ? "true" : "false") : n.stringValue))
            default:
                rows.append(Row(path: path, depth: depth, kind: "null", preview: "null"))
            }
        }
        walk(json, path: "", depth: 0)
        return rows
    }

    /// Turns an absolute path like `data.items[0].post.id` into what a per-post field needs,
    /// given the results path `data.items` → `post.id`. Leaves other paths untouched.
    static func relativize(_ path: String, toResults resultsPath: String) -> String {
        let base = resultsPath.trimmingCharacters(in: .whitespaces)
        let prefixes: [String]
        if base.isEmpty {
            prefixes = ["[0].", "[].", "[*]."]
        } else {
            prefixes = (0..<50).map { "\(base)[\($0)]." } + ["\(base)[].", "\(base)[*]."]
        }
        for p in prefixes where path.hasPrefix(p) {
            return String(path.dropFirst(p.count))
        }
        return path
    }

    /// For the "List of results" field: `posts[0]` or `posts[]` → `posts`.
    static func arrayRoot(_ path: String) -> String {
        var p = path
        while let r = p.range(of: #"\[(\d*|\*)\]$"#, options: .regularExpression) {
            p.removeSubrange(r)
        }
        return p
    }
}
