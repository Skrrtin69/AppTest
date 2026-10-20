import Foundation

extension AutoConfigurator {
    /// Classifies the first results' fields and assembles the proposal with a reason per field.
    struct Builder {
        typealias Key = AdapterConfig.CodingKeys
        let input: AutoConfigInput
        let parts: TemplateParts
        let json: Any
        let list: ListCandidate
        let items: [Any]
        let loggedIn: Bool
        let existingIDs: Set<String>

        var config = AdapterConfig.blank()
        var guesses: FieldGuesses = [:]
        private var thumbIsRelative = false
        private var thumbStartsWithSlash = false
        private var firstThumbValue: String?

        init(input: AutoConfigInput, parts: TemplateParts, json: Any, list: ListCandidate, items: [Any],
             loggedIn: Bool, existingIDs: Set<String>) {
            self.input = input; self.parts = parts; self.json = json; self.list = list
            self.items = items; self.loggedIn = loggedIn; self.existingIDs = existingIDs
        }

        mutating func set(_ k: Key, _ level: Confidence, _ reason: String) {
            guesses[k] = FieldGuess(level: level, reason: reason, value: "")
        }

        static func contains(_ key: String, any words: [String]) -> String? {
            words.first { key.contains($0) }
        }

        // MARK: Main

        /// Returns false if no media address could be found at all.
        mutating func build() -> Bool {
            identity()
            resultsList()

            // Profile up to three results: keep only paths present in all of them.
            let sample = Array(items.prefix(3))
            let maps = sample.map { AutoConfigurator.leaves($0) }
            guard let first = maps.first else { return false }
            let common = first.keys.filter { k in maps.allSatisfy { $0[k] != nil } }.sorted()
            func values(_ p: String) -> [Any] { maps.compactMap { $0[p] } }

            var urlPaths: [String] = []
            var extPaths: [String] = []
            var tagPaths: [(path: String, nameKey: String?)] = []
            var idPaths: [String] = []
            var galleryPaths: [(path: String, urlKey: String?)] = []
            for p in common {
                let vs = values(p)
                let strings = vs.compactMap { $0 as? String }
                if strings.count == vs.count, !strings.isEmpty {
                    // Tags given as one space-separated string ("blue sky_line red"), under a tag-like key.
                    if Self.contains(AutoConfigurator.lastKey(p), any: ["tag", "label", "keyword"]) != nil,
                       !strings.contains(where: { AutoConfigurator.isURLString($0) }) {
                        tagPaths.append((p, nil)); continue
                    }
                    if strings.allSatisfy({ AutoConfigurator.isURLString($0) }) { urlPaths.append(p); continue }
                    if strings.allSatisfy({ AutoConfigurator.isExtensionValue($0) }) { extPaths.append(p); continue }
                    if strings.allSatisfy({ $0.count <= 40 && !$0.contains(" ") && !$0.isEmpty }),
                       Set(strings).count == strings.count { idPaths.append(p) }
                } else if vs.allSatisfy({ ($0 as? NSNumber).map { CFGetTypeID($0) != CFBooleanGetTypeID() && $0.doubleValue == $0.doubleValue.rounded() } ?? false }) {
                    let ints = vs.map { ($0 as! NSNumber).int64Value }
                    if Set(ints).count == ints.count { idPaths.append(p) }
                } else if let arrays = vs as? [[Any]], arrays.contains(where: { !$0.isEmpty }) {
                    let elems = arrays.flatMap { $0 }
                    // A list of addresses (or of objects holding one) = the pages of a gallery.
                    if let strs = elems as? [String], strs.allSatisfy({ AutoConfigurator.isURLString($0) }) {
                        galleryPaths.append((p, nil)); continue
                    }
                    if let objs = elems as? [[String: Any]],
                       let k = ["url", "src", "file", "image", "href"].first(where: { k in objs.allSatisfy { ($0[k] as? String).map(AutoConfigurator.isURLString) ?? false } }) {
                        galleryPaths.append((p, k)); continue
                    }
                    if elems.allSatisfy({ $0 is String }) {
                        tagPaths.append((p, nil))
                    } else if let objs = elems as? [[String: Any]], let k = ["name", "tag", "label", "value"].first(where: { k in objs.allSatisfy { $0[k] is String } }) {
                        tagPaths.append((p, k))
                    }
                }
            }

            guard assignURLs(urlPaths, values: values) else { return false }
            assignID(idPaths)
            assignType(extPaths)
            assignTags(tagPaths)
            assignTagSpaces()
            assignAlternates()
            assignGallery(galleryPaths)
            assignMetadata(common, values: values)
            assignPostPath(maps.first ?? [:])
            pagination()
            return true
        }

        // MARK: Identity and addresses

        mutating func identity() {
            let isLocal = parts.host.hasPrefix("127.") || parts.host.hasPrefix("localhost") ||
                parts.host.split(separator: ":").first.map { $0.allSatisfy { $0.isNumber || $0 == "." } } == true
            let hostName = parts.host.split(separator: ":").first.map(String.init) ?? parts.host
            var base = AutoConfigurator.slug(hostName.hasPrefix("www.") ? String(hostName.dropFirst(4)) : hostName)
            var name = Self.titleCase(hostName)
            // Numeric/local hosts say nothing about the site; add the first folder to tell them apart.
            if isLocal, let seg = parts.firstSegment { base += "-" + AutoConfigurator.slug(seg); name += " " + seg.capitalized }
            var id = base, n = 2
            while existingIDs.contains(id) { id = "\(base)-\(n)"; n += 1 }
            config.id = id
            config.displayName = n > 2 ? "\(name) \(n - 1)" : name
            set(.id, .high, "Made from the site's address (\(id))\(id != base ? "; a number was added because \(base) is already used" : "").")
            set(.displayName, .high, "Made from the host name \(hostName)\(isLocal && parts.firstSegment != nil ? " plus its first folder" : ""). Rename it to anything you like.")

            if let u = URL(string: parts.base) ?? URL(string: parts.origin) { config.baseURL = u }
            set(.baseURL, .high, parts.base == parts.origin
                ? "The scheme and host of your search address."
                : "The scheme, host and first folder (/\(parts.firstSegment ?? "")) of your search address.")
            config.searchPath = parts.rest
            if !input.urlTemplate.contains("{tags}") {
                set(.searchPath, .low, "Your address has no {tags} placeholder, so every search returns the same results. Put {tags} where the search words go.")
            } else {
                set(.searchPath, .high, "The rest of your search address, with your placeholders kept as typed.")
            }
            config.requiresAuth = loggedIn
            set(.requiresAuth, .high, loggedIn
                ? "The server refused to answer (401/403) until you added a login."
                : "The server answered without any login.")
            config.authStyle = input.authStyle ?? .none
            set(.authStyle, .high, loggedIn
                ? "You chose \(config.authStyle.rawValue), and the server accepted it."
                : "No login needed, so none is set.")
            config.authParamName = AdapterConfig.sanitizeParamName(input.authParamName)
            config.authUserParamName = AdapterConfig.sanitizeParamName(input.authUserParamName)
            set(.authParamName, config.authParamName == nil ? .medium : .high, config.authParamName == nil
                ? "Only used by API-key logins; not needed here."
                : "The key name you entered (\(config.authParamName!)).")
            config.rateLimitPerSecond = 2
            set(.rateLimitPerSecond, .medium, "Safe default of 2 requests per second. Raise it if the site allows more.")
            config.timeoutSeconds = 20
            set(.timeoutSeconds, .medium, "Standard 20-second wait (Analyze used 30 seconds to be patient).")
            config.headers = input.headers
            set(.headers, .high, input.headers.isEmpty ? "You didn't add any headers, and none were needed." : "The \(input.headers.count) header(s) you entered, which the server accepted.")
            config.tagSeparator = " "
            set(.tagSeparator, .medium, "A space between tags (sent as %20). Some sites want + instead; change it if multi-tag searches find nothing.")
            config.firstPageIndex = 1
            set(.firstPageIndex, .medium, "Pages are counted from 1, like most sites. Use 0 if the first page comes back empty.")
            config.videoExtensions = ["mp4", "webm", "mov", "m4v"]
            set(.videoExtensions, .medium, "Standard video types; add more if the site uses others.")
            config.gifExtensions = ["gif"]
            set(.gifExtensions, .medium, "Standard animated-GIF type.")
            config.sortOptions = []
            set(.sortOptions, .medium, "The answer doesn't list sort choices. Add the site's own words (like newest) if it has any.")
            config.ratingOptions = []
            set(.ratingOptions, .medium, "The answer doesn't list rating choices. Add them if the site has any.")
            config.userAgent = nil
            set(.userAgent, .medium, "MediaDeck's own User-Agent worked, so no custom one is set.")
            config.proxyHost = nil; config.proxyPort = nil
            set(.proxyHost, .medium, "Not needed: the server answered directly.")
            set(.proxyPort, .medium, "Not needed: no proxy is set.")
            config.authCheckPath = nil
            set(.authCheckPath, .medium, loggedIn
                ? "Not found automatically. The app keeps using a saved login until the server refuses it."
                : "Not needed: the site doesn't require a login.")
            config.postResultPath = nil
            set(.postResultPath, .medium, "Not needed unless you open single posts by ID.")
            config.randomTag = nil
            set(.randomTag, .medium, "Not found automatically. The dice button uses a Sort choice containing 'random' if there is one.")
        }

        mutating func resultsList() {
            config.searchResultsPath = list.path
            let shown = list.path.isEmpty ? "the answer itself" : "'\(list.path)'"
            if list.nameMatched && list.count >= 3 && list.sharedKeys {
                set(.searchResultsPath, .high, "\(shown.prefix(1).uppercased() + shown.dropFirst()) is a list of \(list.count) results that all have the same fields, and its name means results.")
            } else if list.count >= 3 && list.sharedKeys {
                set(.searchResultsPath, .medium, "\(shown.prefix(1).uppercased() + shown.dropFirst()) is the biggest list of \(list.count) items with matching fields, but its name doesn't say 'results'.")
            } else {
                set(.searchResultsPath, .low, "\(shown.prefix(1).uppercased() + shown.dropFirst()) was the best list found (\(list.count) item(s)), but it's small or its items differ. Check it in the Field Mapper.")
            }
        }

        // MARK: URLs

        static let thumbWords = ["thumb", "preview", "sq", "small", "low", "sample", "cover", "poster"]
        static let mediaWords = ["file", "full", "original", "large", "high", "media", "image", "video", "src", "url", "source"]

        mutating func assignURLs(_ urlPaths: [String], values: (String) -> [Any]) -> Bool {
            guard !urlPaths.isEmpty else { return false }
            func strs(_ p: String) -> [String] { values(p).compactMap { $0 as? String } }
            // Web pages (no media file ending) are source candidates, not media.
            let mediaish = urlPaths.filter { strs($0).contains { AutoConfigurator.hasMediaExtension($0) } }
            let sources = urlPaths.filter { p in AutoConfigurator.isHTTP(strs(p).first ?? "") && !strs(p).contains { AutoConfigurator.hasMediaExtension($0) } }
            let noExtensions = mediaish.isEmpty
            let pool = noExtensions ? urlPaths : mediaish
            let key = { (p: String) in AutoConfigurator.lastKey(p) }

            func best(_ paths: [String], words: [String]) -> (String, String)? {
                for w in words { if let p = paths.first(where: { key($0).contains(w) }) { return (p, w) } }
                return nil
            }
            var thumb = best(pool, words: Self.thumbWords)
            // The sample/medium address is a fallback thumbnail only if nothing better exists.
            if let t = thumb, t.1 == "sample", let better = best(pool.filter { $0 != t.0 }, words: Self.thumbWords.filter { $0 != "sample" }) { thumb = better }
            let media = best(pool.filter { $0 != thumb?.0 }, words: Self.mediaWords)

            var thumbPath: String, mediaPath: String
            switch (thumb, media) {
            case let (t?, m?):
                thumbPath = t.0; mediaPath = m.0
                set(.thumbnailURLPath, .high, "Key \(key(t.0)) contains '\(t.1)', so it looks like the small preview picture.")
                set(.mediaURLPath, .high, "Key \(key(m.0)) contains '\(m.1)', so it looks like the full media URL.")
            case let (t?, nil):
                thumbPath = t.0
                let rest = pool.filter { $0 != t.0 }
                mediaPath = rest.max { $0.count < $1.count } ?? t.0
                set(.thumbnailURLPath, .high, "Key \(key(t.0)) contains '\(t.1)', so it looks like the small preview picture.")
                set(.mediaURLPath, .low, rest.isEmpty ? "No separate full-size address found, so the preview address is used for viewing too."
                    : "Key \(key(mediaPath)) doesn't say what it is; picked as the full media because it's the remaining address.")
            case let (nil, m?):
                mediaPath = m.0
                let rest = pool.filter { $0 != m.0 }
                thumbPath = rest.min { $0.count < $1.count } ?? m.0
                set(.mediaURLPath, .high, "Key \(key(m.0)) contains '\(m.1)', so it looks like the full media URL.")
                set(.thumbnailURLPath, .low, rest.isEmpty ? "Only one address found (\(key(m.0))), used for both the thumbnail and the full view."
                    : "Key \(key(thumbPath)) doesn't say what it is; picked as the thumbnail because it's the remaining address.")
            case (nil, nil):
                if pool.count == 1 {
                    thumbPath = pool[0]; mediaPath = pool[0]
                    set(.thumbnailURLPath, .low, "Only URL found (\(key(pool[0]))), used for both — low confidence. Its name doesn't say if it's a preview or the full file.")
                    set(.mediaURLPath, .low, "Only URL found (\(key(pool[0]))), used for both — low confidence. Its name doesn't say if it's a preview or the full file.")
                } else {
                    let sorted = pool.sorted { $0.count < $1.count }
                    thumbPath = sorted.first!; mediaPath = sorted.last!
                    set(.thumbnailURLPath, .low, "Names don't say which is which; \(key(thumbPath)) has the shorter path, so it's guessed as the thumbnail.")
                    set(.mediaURLPath, .low, "Names don't say which is which; \(key(mediaPath)) has the longer path, so it's guessed as the full media.")
                }
            }
            if noExtensions {
                let r = "None of the addresses end in a picture/video type (.jpg, .mp4…), so this is a guess."
                set(.thumbnailURLPath, .low, r + " Check the preview below.")
                set(.mediaURLPath, .low, r + " Check the preview below.")
            }
            config.thumbnailURLPath = AutoConfigurator.relative(thumbPath)
            config.mediaURLPath = AutoConfigurator.relative(mediaPath)

            if let s = pool.first(where: { $0 != thumbPath && $0 != mediaPath && key($0).contains("sample") }) {
                config.sampleURLPath = s
                set(.sampleURLPath, .medium, "Key \(key(s)) contains 'sample', so it's used as the medium size for 'Preview' quality downloads.")
            } else {
                config.sampleURLPath = nil
                set(.sampleURLPath, .medium, "No medium-size address found; 'Preview' quality downloads use the thumbnail.")
            }

            let srcWords = ["source", "link", "permalink", "page", "web", "view", "href"]
            if let s = best(sources, words: srcWords) {
                config.sourceURLPath = s.0
                set(.sourceURLPath, .high, "Key \(key(s.0)) contains '\(s.1)' and holds a web page address (not a picture), so it's the source link.")
            } else if let s = sources.first {
                config.sourceURLPath = s
                set(.sourceURLPath, .low, "\(key(s)) is a web address that isn't a picture or video; guessed as the source page.")
            } else {
                config.sourceURLPath = nil
                set(.sourceURLPath, .medium, "No web-page link found in the results; the Info panel won't show a source.")
            }

            let thumbValue = strs(thumbPath).first ?? ""
            firstThumbValue = thumbValue
            thumbIsRelative = !AutoConfigurator.isHTTP(thumbValue)
            thumbStartsWithSlash = thumbValue.hasPrefix("/")
            return true
        }

        // MARK: Other per-result fields

        mutating func assignID(_ paths: [String]) {
            let exact = ["id", "uid", "_id", "uuid", "guid", "key", "post_id", "postid"]
            if let p = paths.first(where: { exact.contains(AutoConfigurator.lastKey($0)) }) {
                config.postIDPath = p
                set(.postIDPath, .high, "Key \(AutoConfigurator.lastKey(p)) is named like an ID and is different in every result.")
            } else if let p = paths.first(where: { AutoConfigurator.lastKey($0).hasSuffix("id") }) {
                config.postIDPath = p
                set(.postIDPath, .medium, "Key \(AutoConfigurator.lastKey(p)) ends in 'id' and is different in every result.")
            } else if let p = paths.first {
                config.postIDPath = p
                set(.postIDPath, .low, "No key is called id; \(AutoConfigurator.lastKey(p)) is used because it's short and different in every result.")
            } else {
                config.postIDPath = ""
                set(.postIDPath, .low, "Needs input: no value was different in every result, so there's nothing to use as an ID.")
            }
        }

        mutating func assignType(_ paths: [String]) {
            let words = ["ext", "type", "kind", "format", "mime"]
            if let p = paths.first(where: { k in Self.contains(AutoConfigurator.lastKey(k), any: words) != nil }) {
                config.mediaTypePath = p
                set(.mediaTypePath, .high, "Key \(AutoConfigurator.lastKey(p)) holds file types like png or webm.")
            } else if let p = paths.first {
                config.mediaTypePath = p
                set(.mediaTypePath, .medium, "Key \(AutoConfigurator.lastKey(p)) holds file types (png, mp4…) in all of the first results, though its name doesn't say so.")
            } else {
                config.mediaTypePath = ""
                set(.mediaTypePath, .low, "No file-type field found, so the app will decide from each address's ending (.png, .mp4…).")
            }
        }

        mutating func assignTags(_ paths: [(path: String, nameKey: String?)]) {
            let words = ["tag", "label", "keyword", "categor"]
            let pick = paths.first { p in Self.contains(AutoConfigurator.lastKey(p.path), any: words) != nil }
            if let p = pick ?? paths.first {
                config.tagsPath = p.path
                config.tagsNameKey = p.nameKey
                let named = pick != nil
                set(.tagsPath, named ? .high : .medium, named
                    ? "Key \(AutoConfigurator.lastKey(p.path)) is a list of \(p.nameKey == nil ? "words" : "tag objects"), named like tags."
                    : "\(AutoConfigurator.lastKey(p.path)) is the only list of words in each result, so it's used as the tags.")
                set(.tagsNameKey, p.nameKey == nil ? .medium : .high, p.nameKey == nil
                    ? "Tags are plain words, so no name key is needed."
                    : "Each tag is an object; its text is under '\(p.nameKey!)'.")
            } else {
                config.tagsPath = ""; config.tagsNameKey = nil
                set(.tagsPath, .low, "No list of tags found in the results. Tag search still works, but the Info panel and blacklist won't see tags.")
                set(.tagsNameKey, .medium, "Not needed because no tags were found.")
            }
        }

        /// Over 60% of tags written with "_" (or "-") between words → that's how spaces are written.
        mutating func assignTagSpaces() {
            let tags = items.prefix(20).flatMap { DottedPath.strings(config.tagsPath, in: $0, nameKey: config.tagsNameKey) }
            guard !config.tagsPath.isEmpty, !tags.isEmpty else {
                config.tagSpaceReplacement = nil
                set(.tagSpaceReplacement, .medium, "No tags to learn from, so spaces inside a tag are left as they are.")
                return
            }
            let underscore = Double(tags.filter { $0.contains("_") }.count) / Double(tags.count)
            let hyphen = Double(tags.filter { $0.dropFirst().contains("-") }.count) / Double(tags.count)
            if underscore > 0.6 {
                config.tagSpaceReplacement = "_"
                set(.tagSpaceReplacement, .high, "\(Int(underscore * 100))% of \(tags.count) tags use _ between words, so a typed \"blue sky\" is searched as blue_sky.")
            } else if hyphen > 0.6 {
                config.tagSpaceReplacement = "-"
                set(.tagSpaceReplacement, .high, "\(Int(hyphen * 100))% of \(tags.count) tags use - between words, so a typed \"blue sky\" is searched as blue-sky.")
            } else {
                config.tagSpaceReplacement = nil
                set(.tagSpaceReplacement, .medium, "Only \(Int(max(underscore, hyphen) * 100))% of \(tags.count) tags join words with _ or -, so spaces inside a tag are left as they are.")
            }
        }

        /// Other MP4/MOV addresses in the results (often only on video posts) become alternates.
        mutating func assignAlternates() {
            let taken = Set([config.mediaURLPath, config.thumbnailURLPath, config.sampleURLPath ?? ""])
            var found: [String] = []
            for item in items.prefix(30) {
                for (p, v) in AutoConfigurator.leaves(item) where !taken.contains(p) && !found.contains(p) {
                    if let s = v as? String, AutoConfigurator.isURLString(s),
                       ["mp4", "m4v", "mov"].contains(((s.split(separator: "?").first.map(String.init) ?? s) as NSString).pathExtension.lowercased()) {
                        found.append(p)
                    }
                }
            }
            config.alternateMediaURLPaths = found.sorted()
            set(.alternateMediaURLPaths, found.isEmpty ? .medium : .high, found.isEmpty
                ? "No second (MP4) version of the media found in the first results."
                : "Some results also have an MP4 at \(found.joined(separator: ", ")); it will be preferred so videos play natively with sound.")
        }

        /// A list of page addresses in each result → multi-page gallery.
        mutating func assignGallery(_ paths: [(path: String, urlKey: String?)]) {
            let words = ["page", "image", "gallery", "file", "photo", "picture"]
            guard let g = paths.first(where: { Self.contains(AutoConfigurator.lastKey($0.path).lowercased(), any: words) != nil }) ?? paths.first else {
                config.galleryPath = nil; config.galleryURLKey = nil
                set(.galleryPath, .medium, "No list of pages found, so every result is a single picture or video.")
                set(.galleryURLKey, .medium, "Not needed because there are no gallery pages.")
                return
            }
            config.galleryPath = g.path
            config.galleryURLKey = g.urlKey
            set(.galleryPath, .high, "Key \(AutoConfigurator.lastKey(g.path)) is a list of addresses, so results with several of them open as a scrolling gallery.")
            set(.galleryURLKey, g.urlKey == nil ? .medium : .high, g.urlKey == nil
                ? "Pages are plain addresses, so no key is needed."
                : "Each page is an object; its address is under '\(g.urlKey!)'.")
        }

        /// Tries common suggestion addresses next to the API (then at the site root); the first
        /// that answers with a list of tag-like items wins.
        mutating func probeAutocomplete(adapter: GenericAdapter) async {
            let patterns = ["tags/autocomplete.json?q={query}", "tags/autocomplete?q={query}", "autocomplete.json?q={query}",
                            "autocomplete?q={query}", "suggest?q={query}", "tags.json?q={query}"]
            let query = String((input.sampleTag.split(separator: " ").first ?? "a").prefix(2))
            let bases = parts.base == parts.origin ? [parts.base] : [parts.base, parts.origin]
            for base in bases {
                for pattern in patterns {
                    let filled = pattern.replacingOccurrences(of: "{query}", with: GenericAdapter.encode(query))
                    guard let url = URL(string: GenericAdapter.join(base, filled)),
                          let (data, resp) = try? await adapter.fetchRaw(url, rateLimited: false),
                          (200...299).contains(resp.statusCode),
                          let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
                          let found = Self.suggestionList(json) else { continue }
                    // Under the API folder it's written relative to baseURL; at the root, as a full address.
                    config.autocompletePath = base == parts.base ? pattern : GenericAdapter.join(base, pattern)
                    config.autocompleteResultsPath = found.path
                    config.autocompleteNameKey = found.nameKey
                    set(.autocompletePath, .high, "\(GenericAdapter.join(base, filled)) answered with \(found.count) tag suggestions for '\(query)'.")
                    set(.autocompleteResultsPath, .high, found.path.isEmpty ? "The suggestion answer is itself the list." : "Suggestions are listed under '\(found.path)'.")
                    set(.autocompleteNameKey, found.nameKey == nil ? .medium : .high, found.nameKey == nil
                        ? "Suggestions are plain words, so no name key is needed."
                        : "Each suggestion's text is under '\(found.nameKey!)'.")
                    return
                }
            }
            config.autocompletePath = nil
            set(.autocompletePath, .medium, "None of the usual suggestion addresses answered, so the search bar won't suggest tags. Add one if the site has it.")
            set(.autocompleteResultsPath, .medium, "Not needed without suggestions.")
            set(.autocompleteNameKey, .medium, "Not needed without suggestions.")
        }

        /// A list of strings, or of objects with a name-like key, at the root or nested in objects.
        static func suggestionList(_ json: Any) -> (path: String, nameKey: String?, count: Int)? {
            /// nil = not a suggestion list; .some((nil, n)) = list of plain strings.
            func check(_ v: Any) -> (nameKey: String?, count: Int)? {
                guard let a = v as? [Any], !a.isEmpty else { return nil }
                if a.allSatisfy({ $0 is String }) { return (nil, a.count) }
                let objs = a.compactMap { $0 as? [String: Any] }
                guard objs.count == a.count else { return nil }
                for k in ["name", "label", "tag", "value", "term", "title"] where objs.allSatisfy({ $0[k] is String }) {
                    return (k, a.count)
                }
                return nil
            }
            if let found = check(json) { return ("", found.nameKey, found.count) }
            var result: (path: String, nameKey: String?, count: Int)?
            func walk(_ v: Any, path: String, depth: Int) {
                guard result == nil, let d = v as? [String: Any], depth < 4 else { return }
                for (k, child) in d {
                    let p = path.isEmpty ? k : "\(path).\(k)"
                    if let found = check(child) { result = (p, found.nameKey, found.count); return }
                    walk(child, path: p, depth: depth + 1)
                }
            }
            walk(json, path: "", depth: 0)
            return result
        }

        mutating func assignMetadata(_ common: [String], values: (String) -> [Any]) {
            var meta: [String: String] = [:]
            for p in common where values(p).allSatisfy({ $0 is NSNumber }) {
                switch AutoConfigurator.lastKey(p) {
                case "width", "w": meta["width"] = p
                case "height", "h": meta["height"] = p
                case "score", "likes", "favorites", "views": meta[AutoConfigurator.lastKey(p)] = p
                default: break
                }
            }
            config.metadataPaths = meta
            set(.metadataPaths, .medium, meta.isEmpty
                ? "No size or score numbers found to show in the Info panel."
                : "Found \(meta.keys.sorted().joined(separator: ", ")) numbers for the Info panel.")
        }

        mutating func assignPostPath(_ firstLeaves: [String: Any]) {
            let idValue = DottedPath.string(config.postIDPath, in: items.first ?? [:]) ?? ""
            let strings = firstLeaves.values.compactMap { $0 as? String }.filter { AutoConfigurator.isHTTP($0) || $0.hasPrefix("/") }
            for s in strings where !idValue.isEmpty {
                for seg in ["posts", "post", "items", "item"] {
                    for suffix in [".json", ""] {
                        let needle = "/\(seg)/\(idValue)\(suffix)"
                        guard let r = s.range(of: needle) else { continue }
                        let prefix = String(s[..<r.lowerBound])
                        var template = "\(seg)/{id}\(suffix)"
                        // Keep anything between the base address and /post/ (e.g. /api/v1).
                        if let base = prefix.range(of: config.baseURL.absoluteString) {
                            let mid = prefix[base.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                            if !mid.isEmpty { template = "\(mid)/\(template)" }
                        }
                        config.postPath = template
                        set(.postPath, .medium, "A result address contains \(needle), so single posts look like \(template).")
                        return
                    }
                }
            }
            config.postPath = ""
            set(.postPath, .medium, "Needs input (optional): no single-post address appeared in the results. Browsing doesn't need it.")
        }

        // MARK: Pages

        mutating func pagination() {
            var hasNext: String?, cursor: String?, counters: [String] = []
            func walk(_ v: Any, path: String, depth: Int) {
                guard let d = v as? [String: Any], depth < 5 else { return }
                for (k, child) in d {
                    let p = path.isEmpty ? k : "\(path).\(k)"
                    if p == list.path { continue }
                    let lk = k.lowercased()
                    if let b = child as? NSNumber, CFGetTypeID(b) == CFBooleanGetTypeID(),
                       ["has_more", "has_next", "hasmore", "hasnext", "has_next_page", "next_page", "more", "next"].contains(lk) {
                        hasNext = hasNext ?? p
                    } else if ["next_cursor", "cursor", "nextcursor", "next_page_token", "after", "continuation"].contains(lk),
                              child is NSNull || ((child as? String).map { !$0.isEmpty && !AutoConfigurator.isHTTP($0) } ?? false) {
                        // null counts too: on the last page the token is simply empty.
                        cursor = cursor ?? p
                    } else if lk == "next", let s = child as? String, !s.isEmpty, !AutoConfigurator.isHTTP(s) {
                        cursor = cursor ?? p
                    } else if child is NSNumber, ["page", "count", "total", "pages", "next_page"].contains(lk) {
                        counters.append(p)
                    } else if child is [String: Any] {
                        walk(child, path: p, depth: depth + 1)
                    }
                }
            }
            walk(json, path: "", depth: 0)

            if let c = cursor {
                config.paginationStyle = .cursor
                config.cursorPath = c
                set(.paginationStyle, .high, "The answer has a next-page token (\(c)), so pages are fetched by cursor.")
                set(.cursorPath, .high, "Key \(AutoConfigurator.lastKey(c)) holds the token for the next page.")
                if !input.urlTemplate.contains("{cursor}") {
                    set(.searchPath, .low, "Pages use a token, but your address has no {cursor} placeholder. Add it (e.g. &cursor={cursor}) or only page 1 will load.")
                }
            } else if input.urlTemplate.contains("{cursor}") {
                config.paginationStyle = .cursor
                config.cursorPath = nil
                set(.paginationStyle, .medium, "Your address uses {cursor}, so pages are fetched by token, but this answer had no token key (it may have been the only page).")
                set(.cursorPath, .low, "Needs input: the answer didn't show where the next-page token is. Try Analyze with a sample tag that has more results.")
            } else {
                config.paginationStyle = .pageNumber
                config.cursorPath = nil
                if input.urlTemplate.contains("{page}") {
                    set(.paginationStyle, .high, "Your address has {page} and the answer has no next-page token, so pages are numbered.")
                } else {
                    set(.paginationStyle, .low, "No {page} placeholder and no next-page token, so only the first page may load. Add {page} to the address if the site supports it.")
                }
                set(.cursorPath, .medium, "No next-page token in the answer; not needed for numbered pages.")
            }
            if let h = hasNext {
                config.hasNextPagePath = h
                set(.hasNextPagePath, .high, "Key \(AutoConfigurator.lastKey(h)) is true/false and says whether more pages exist.")
            } else {
                config.hasNextPagePath = nil
                set(.hasNextPagePath, .medium, counters.isEmpty
                    ? "No 'more pages' flag; the app keeps loading until a page comes back empty."
                    : "Only counters (\(counters.map(AutoConfigurator.lastKey).joined(separator: ", "))) found, no true/false flag; the app stops when a page comes back empty.")
            }
        }

        // MARK: Media base (needs the network)

        /// Absolute addresses don't need it. Relative ones are tried against the API folder and the
        /// site root; the first that actually loads wins.
        mutating func chooseMediaBase(adapter: GenericAdapter) async {
            guard let folder = URL(string: parts.base + "/"), let root = URL(string: parts.origin + "/") else {
                set(.mediaBaseURL, .low, "Couldn't build a base address from the search address.")
                return
            }
            guard thumbIsRelative, let value = firstThumbValue, !value.isEmpty else {
                config.mediaBaseURL = root
                set(.mediaBaseURL, .high, "Result addresses are complete (start with http), so this is only a fallback.")
                return
            }
            let candidates = thumbStartsWithSlash ? [root] : [folder, root]
            for base in candidates {
                var c = config
                c.mediaBaseURL = base
                guard let url = GenericAdapter(config: c, client: adapter.client).resolve(value),
                      let (_, resp) = try? await adapter.client.data(for: url, rateLimited: false, acceptAnyStatus: true),
                      (200...299).contains(resp.statusCode) else { continue }
                config.mediaBaseURL = base
                set(.mediaBaseURL, .high, "Addresses like '\(value.prefix(40))' are relative; joined to \(base.absoluteString) they loaded correctly.")
                return
            }
            config.mediaBaseURL = candidates.first!
            set(.mediaBaseURL, .low, "Addresses like '\(value.prefix(40))' are relative, and joining them to \(candidates.map { $0.absoluteString }.joined(separator: " or ")) didn't load. Check the preview.")
        }

        /// Records each guess's value so later edits can be noticed.
        mutating func finish() {
            for (k, g) in guesses { guesses[k] = FieldGuess(level: g.level, reason: g.reason, value: config.jsonValue(for: k)) }
            for k in AdapterConfig.CodingKeys.allCases where guesses[k] == nil {
                guesses[k] = FieldGuess(level: .medium, reason: "Left at the standard default.", value: config.jsonValue(for: k))
            }
        }

        static func titleCase(_ host: String) -> String {
            var h = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            if h.allSatisfy({ $0.isNumber || $0 == "." }) { return h }
            let parts = h.split(separator: ".")
            if parts.count >= 2 { h = parts.dropLast().joined(separator: " ") }
            return h.split(whereSeparator: { $0 == " " || $0 == "-" }).map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        }
    }

    /// Per-post fields are relative to one result; the profiling paths already are.
    static func relative(_ p: String) -> String { p }
}
