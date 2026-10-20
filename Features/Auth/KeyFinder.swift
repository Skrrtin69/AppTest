import Foundation

/// Reads a logged-in web page and finds the API key (and user ID) by context:
/// text next to an "API Key"-style label, `api_key=` / `user_id=` in example addresses,
/// and input boxes labeled as keys. Nothing is guessed from random long strings.
enum KeyFinder {
    struct Found: Identifiable, Hashable {
        enum Source: Int { case selection, input, label, param }
        var value: String
        /// The label or parameter it was found next to, as written on the page.
        var label: String
        var source: Source
        /// The address parameter name, when the page shows one (e.g. "api_key").
        var paramName: String?
        var id: String { value }

        var context: String {
            switch source {
            case .selection: return "From \(label)"
            case .input: return "In the box labeled '\(label)'"
            case .label: return "Found next to '\(label)'"
            case .param: return "Found in '\(label)=' in an example address"
            }
        }
    }

    struct Result {
        var keys: [Found] = []
        var userID: Found?
    }

    static let keyLabels = ["api key", "api-key", "api_key", "apikey", "api token", "api-token", "api_token",
                            "access token", "access key", "secret", "credentials"]
    static let userLabels = ["user id", "user-id", "user_id", "userid"]

    /// Runs in the page; returns visible text plus every filled-in visible text box with its label.
    static let pageScript = """
    (function(){
      function txt(n){ return n ? (n.innerText || n.textContent || '') : ''; }
      function lab(e){
        var t = '';
        if (e.id) { var l = document.querySelector('label[for="' + e.id.replace(/"/g,'') + '"]'); if (l) t = txt(l); }
        if (!t) { var p = e.closest('label'); if (p) t = txt(p); }
        if (!t) t = e.getAttribute('aria-label') || '';
        if (!t) { var s = e.previousElementSibling; while (s && !txt(s).trim()) s = s.previousElementSibling; if (s) t = txt(s); }
        if (!t && e.parentElement) { var ps = e.parentElement.previousElementSibling; if (ps) t = txt(ps); }
        if (!t) t = e.placeholder || '';
        return (t.trim().slice(-80) + ' ' + (e.name || '') + ' ' + (e.id || '')).trim();
      }
      var skip = ['hidden','password','submit','button','checkbox','radio','file','image','reset'];
      var inputs = [].slice.call(document.querySelectorAll('input,textarea')).filter(function(e){
        return e.value && skip.indexOf((e.type || '').toLowerCase()) < 0;
      }).map(function(e){ return { label: lab(e), value: String(e.value).slice(0, 300) }; });
      var sel = String(window.getSelection ? window.getSelection() : '');
      var a = document.activeElement;
      if (!sel.trim() && a && typeof a.selectionStart === 'number' && a.selectionEnd > a.selectionStart) {
        sel = String(a.value).slice(a.selectionStart, a.selectionEnd);
      }
      return JSON.stringify({ text: document.body ? document.body.innerText : '', inputs: inputs, selection: sel.slice(0, 2000) });
    })()
    """

    /// Parses `pageScript`'s answer.
    static func find(json: String) -> Result {
        guard let d = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return Result() }
        let inputs = (d["inputs"] as? [[String: Any]] ?? []).compactMap { i -> (String, String)? in
            guard let l = i["label"] as? String, let v = i["value"] as? String else { return nil }
            return (l, v)
        }
        let page = find(text: d["text"] as? String ?? "", inputs: inputs)
        // Highlighted text wins: parse it first, and use the page only for what it lacks.
        if let sel = (d["selection"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !sel.isEmpty {
            var picked = find(text: sel, inputs: [])
            if picked.keys.isEmpty, isKey(sel) {
                picked.keys = [Found(value: sel, label: "your highlighted text", source: .selection)]
            }
            if !picked.keys.isEmpty {
                if picked.userID == nil { picked.userID = page.userID }
                return picked
            }
        }
        return page
    }

    static func find(text: String, inputs: [(label: String, value: String)]) -> Result {
        var keys: [Found] = []
        var users: [Found] = []

        // 1. Text boxes labeled as a key / user ID.
        for i in inputs {
            let v = i.value.trimmingCharacters(in: .whitespacesAndNewlines)
            let inBox = params(in: v)
            if !inBox.keys.isEmpty || !inBox.users.isEmpty {
                keys += inBox.keys
                users += inBox.users
                continue
            }
            if let l = match(keyLabels, in: i.label), isKey(v) {
                keys.append(Found(value: v, label: l, source: .input))
            } else if let l = match(userLabels, in: i.label), isUserID(v) {
                users.append(Found(value: v, label: l, source: .input))
            }
        }

        // 2. Text right after a label ("API Key: abc…"), or on the next line when the label
        //    stands alone (tables and definition lists put the value on its own line).
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        for (n, line) in lines.enumerated() where !line.isEmpty {
            for (labels, isKeyKind) in [(keyLabels, true), (userLabels, false)] {
                for l in labels {
                    guard let r = line.range(of: l, options: .caseInsensitive) else { continue }
                    let shown = String(line[r])
                    var rest = String(line[r.upperBound...])
                    // "(legacy apps)" and similar notes between the label and the value.
                    rest = rest.replacingOccurrences(of: "^\\s*\\([^)]*\\)", with: "", options: .regularExpression)
                    // Parameter forms (api_key=…) are handled separately.
                    if rest.hasPrefix("=") { continue }
                    rest = rest.replacingOccurrences(of: "^[\\s:：\\-–—]+", with: "", options: .regularExpression)
                    var value = firstToken(rest)
                    if value == nil, rest.trimmingCharacters(in: .whitespaces).isEmpty,
                       let next = lines[(n + 1)...].prefix(2).first(where: { !$0.isEmpty }) {
                        // The value is the whole next line.
                        if let t = firstToken(next), t.count >= next.count - 1 { value = t }
                    }
                    guard let v = value else { continue }
                    if isKeyKind, isKey(v) { keys.append(Found(value: v, label: shown, source: .label)) }
                    if !isKeyKind, isUserID(v) { users.append(Found(value: v, label: shown, source: .label)) }
                    break
                }
            }
        }

        // 3. api_key=… / user_id=… anywhere (example addresses, "&api_key=…&user_id=…").
        let found = params(in: text)
        keys += found.keys
        users += found.users

        var result = Result()
        result.keys = merge(keys)
        let userIDs = merge(users).filter { u in !result.keys.contains { $0.value == u.value } }
        result.userID = userIDs.first
        return result
    }

    /// Every `name=value` whose name ends in key/token or is a user ID. The name may follow
    /// anything (`&`, `?`, a space, the start of a box); the value runs to the next `&`,
    /// space or quote.
    static func params(in text: String) -> (keys: [Found], users: [Found]) {
        let re = try! NSRegularExpression(pattern: "(?i)(?<![A-Za-z0-9])([a-z_]*(?:key|token)|user_?id)\\s*=\\s*([^&\\s\"'<>#;,]+)")
        let ns = text as NSString
        var keys: [Found] = [], users: [Found] = []
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: m.range(at: 1))
            let value = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: CharacterSet(charactersIn: ".)]}"))
            if name.lowercased().contains("user") {
                if isUserID(value) { users.append(Found(value: value, label: name, source: .param, paramName: name)) }
            } else if isKey(value) {
                keys.append(Found(value: value, label: name, source: .param, paramName: name))
            }
        }
        return (keys, users)
    }

    /// One entry per value, keeping the clearest context and any parameter name seen.
    private static func merge(_ list: [Found]) -> [Found] {
        var out: [Found] = []
        for f in list.sorted(by: { $0.source.rawValue < $1.source.rawValue }) {
            if let i = out.firstIndex(where: { $0.value == f.value }) {
                if out[i].paramName == nil { out[i].paramName = f.paramName }
            } else {
                out.append(f)
            }
        }
        return out
    }

    private static func match(_ labels: [String], in s: String) -> String? {
        for l in labels { if let r = s.range(of: l, options: .caseInsensitive) { return String(s[r]) } }
        return nil
    }

    private static func firstToken(_ s: String) -> String? {
        guard let r = s.range(of: "^[A-Za-z0-9][A-Za-z0-9_\\-.]*", options: .regularExpression) else { return nil }
        var t = String(s[r])
        while t.hasSuffix(".") { t.removeLast() }
        return t.isEmpty ? nil : t
    }

    /// Keys are long codes: 8+ characters with a digit, or 20+ characters.
    static func isKey(_ v: String) -> Bool {
        guard v.count >= 8, v.count <= 300, v.range(of: "^[A-Za-z0-9_\\-.]+$", options: .regularExpression) != nil else { return false }
        return v.rangeOfCharacter(from: .decimalDigits) != nil || v.count >= 20
    }

    static func isUserID(_ v: String) -> Bool {
        v.count <= 40 && v.range(of: "^[A-Za-z0-9_\\-]+$", options: .regularExpression) != nil
            && v.rangeOfCharacter(from: .decimalDigits) != nil
    }
}
