import Foundation

/// Suggestion engine for the search field. Given the current input, cursor
/// position, and available entity/area context, returns the word being
/// completed (its range) and a ranked list of candidate replacements.
///
/// Completion triggers in two shapes:
/// 1. Value completion — cursor sits in a `key:partial` where `key` is known.
///    Suggests matching values for that key. An empty partial shows all.
/// 2. Key completion — cursor sits in a bare word with no colon yet. Suggests
///    full `key:` prefixes.
enum SearchSuggestion {
    struct Context {
        let input: String
        /// Cursor position as a UTF-16 offset (NSTextField convention).
        let cursor: Int
        let domains: [String]
        let areaNames: [String]
        let alreadyUsedTokens: [SearchQuery.Token]
    }

    struct Result: Equatable {
        /// UTF-16 range in the input that the chosen suggestion replaces.
        let replaceRange: NSRange
        let suggestions: [String]
        /// If true, accepting the suggestion should append a trailing space.
        let addTrailingSpace: Bool
    }

    static let keyPrefixes: [String] = ["is:", "domain:", "area:"]

    static func compute(_ ctx: Context) -> Result? {
        let ns = ctx.input as NSString
        guard ctx.cursor >= 0, ctx.cursor <= ns.length else { return nil }

        // Find the start of the current "word" (run of non-whitespace ending at cursor).
        var start = ctx.cursor
        while start > 0 {
            let prev = ns.substring(with: NSRange(location: start - 1, length: 1))
            if prev.first?.isWhitespace == true { break }
            start -= 1
        }
        let wordRange = NSRange(location: start, length: ctx.cursor - start)
        let word = ns.substring(with: wordRange)

        // Value completion: word contains a colon with a recognized key.
        if let colonIdx = word.firstIndex(of: ":") {
            let key = word[word.startIndex..<colonIdx].lowercased()
            let partial = String(word[word.index(after: colonIdx)...]).lowercased()
            let values = candidateValues(forKey: key, ctx: ctx)
            guard !values.isEmpty else { return nil }
            let filtered = values.filter { partial.isEmpty || $0.hasPrefix(partial) }
            let replacements = filtered.map { "\(key):\($0)" }
            let replace = NSRange(location: start, length: word.utf16.count)
            return Result(replaceRange: replace, suggestions: replacements, addTrailingSpace: true)
        }

        // Key completion: bare partial word. Show matching keys.
        let partial = word.lowercased()
        let keys = keyPrefixes.filter { partial.isEmpty || $0.hasPrefix(partial) }
        guard !keys.isEmpty else { return nil }
        let replace = NSRange(location: start, length: word.utf16.count)
        return Result(replaceRange: replace, suggestions: keys, addTrailingSpace: false)
    }

    private static func candidateValues(forKey key: String, ctx: Context) -> [String] {
        switch key {
        case "is":
            let used: Set<String> = Set(ctx.alreadyUsedTokens.compactMap {
                if case .isFacet(let f) = $0 { return f.rawValue } else { return nil }
            })
            return SearchQuery.IsFacet.allCases
                .map(\.rawValue)
                .filter { !used.contains($0) }
        case "domain":
            let used: Set<String> = Set(ctx.alreadyUsedTokens.compactMap {
                if case .domain(let d) = $0 { return d } else { return nil }
            })
            return ctx.domains
                .map { $0.lowercased() }
                .uniqueStable()
                .filter { !used.contains($0) }
                .sorted()
        case "area":
            let used: Set<String> = Set(ctx.alreadyUsedTokens.compactMap {
                if case .area(let a) = $0 { return SearchQuery.normalizeArea(a) } else { return nil }
            })
            return ctx.areaNames
                .map { SearchQuery.normalizeArea($0).replacingOccurrences(of: " ", with: "_") }
                .uniqueStable()
                .filter { !used.contains(SearchQuery.normalizeArea($0)) }
                .sorted()
        default:
            return []
        }
    }
}

private extension Array where Element: Hashable {
    func uniqueStable() -> [Element] {
        var seen = Set<Element>()
        var out: [Element] = []
        for x in self where seen.insert(x).inserted {
            out.append(x)
        }
        return out
    }
}
