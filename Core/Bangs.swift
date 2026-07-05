import Foundation

// MARK: - Bangs
//
// DuckDuckGo-style `!bang` shortcuts, resolved locally so no third party sees
// the query (Helium's native-bangs win). A bang is just a hidden search engine
// keyed on `!trigger`; the rest of the input fills its query template.
//
// Parsing follows Helium: a `!token` counts when it is at the start of the input
// or preceded by whitespace, so `!w cats`, `cats !w`, and `find !w cats` all
// resolve `!w` with the remaining words as the query. An empty query navigates
// to the engine's home page.

enum BangCategory {
    case ai
    case other
}

struct Bang {
    let trigger: String        // without the leading "!"
    let name: String           // human label, e.g. "Wikipedia"
    let template: String       // %@ is replaced with the encoded query
    let home: String           // where an empty-query bang goes
    let category: BangCategory

    init(_ trigger: String, _ name: String, _ template: String,
         home: String, category: BangCategory = .other) {
        self.trigger = trigger
        self.name = name
        self.template = template
        self.home = home
        self.category = category
    }

    /// Host used to fetch a favicon for suggestion rows.
    var faviconHost: String? { URL(string: home)?.host }
}

enum Bangs {
    /// Settings ▸ General ▸ Features toggle. Off → no bang resolution and no
    /// bang suggestion rows; `!w cats` falls through to a plain search.
    static var enabled: Bool {
        UserDefaults.standard.object(forKey: "BangsEnabled") as? Bool ?? true
    }

    /// Curated starter set of the most-used bangs. Bundled (no network), so
    /// they work regardless of the default engine. Extend freely.
    static let all: [Bang] = [
        // Search engines
        Bang("g", "Google", "https://www.google.com/search?q=%@", home: "https://www.google.com"),
        Bang("ddg", "DuckDuckGo", "https://duckduckgo.com/?q=%@", home: "https://duckduckgo.com"),
        Bang("b", "Brave Search", "https://search.brave.com/search?q=%@", home: "https://search.brave.com"),
        Bang("bing", "Bing", "https://www.bing.com/search?q=%@", home: "https://www.bing.com"),
        // Reference
        Bang("w", "Wikipedia", "https://en.wikipedia.org/w/index.php?search=%@", home: "https://en.wikipedia.org"),
        Bang("wa", "Wolfram Alpha", "https://www.wolframalpha.com/input?i=%@", home: "https://www.wolframalpha.com"),
        Bang("mdn", "MDN", "https://developer.mozilla.org/en-US/search?q=%@", home: "https://developer.mozilla.org"),
        // Dev
        Bang("gh", "GitHub", "https://github.com/search?q=%@", home: "https://github.com"),
        Bang("so", "Stack Overflow", "https://stackoverflow.com/search?q=%@", home: "https://stackoverflow.com"),
        Bang("npm", "npm", "https://www.npmjs.com/search?q=%@", home: "https://www.npmjs.com"),
        // Media / shopping / social
        Bang("yt", "YouTube", "https://www.youtube.com/results?search_query=%@", home: "https://www.youtube.com"),
        Bang("a", "Amazon", "https://www.amazon.com/s?k=%@", home: "https://www.amazon.com"),
        Bang("r", "Reddit", "https://www.reddit.com/search/?q=%@", home: "https://www.reddit.com"),
        Bang("x", "X", "https://x.com/search?q=%@", home: "https://x.com"),
        Bang("maps", "Google Maps", "https://www.google.com/maps/search/%@", home: "https://www.google.com/maps"),
        Bang("gi", "Google Images", "https://www.google.com/search?tbm=isch&q=%@", home: "https://images.google.com"),
        // AI assistants (spark glyph + "Ask %@")
        Bang("chatgpt", "ChatGPT", "https://chatgpt.com/?q=%@", home: "https://chatgpt.com", category: .ai),
        Bang("claude", "Claude", "https://claude.ai/new?q=%@", home: "https://claude.ai", category: .ai),
        Bang("perplexity", "Perplexity", "https://www.perplexity.ai/search?q=%@", home: "https://www.perplexity.ai", category: .ai),
    ]

    private static let byTrigger: [String: Bang] = {
        var m: [String: Bang] = [:]
        for b in all { m[b.trigger] = b }
        return m
    }()

    /// The first `!token` at a word boundary, plus the query built from every
    /// other word. Returns nil when the input has no bang token.
    private static func split(_ input: String) -> (bang: Bang, query: String)? {
        let words = input.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let idx = words.firstIndex(where: { $0.hasPrefix("!") && $0.count > 1 }) else { return nil }
        let trigger = String(words[idx].dropFirst()).lowercased()
        guard let bang = byTrigger[trigger] else { return nil }
        let query = words.enumerated().filter { $0.offset != idx }.map { $0.element }.joined(separator: " ")
        return (bang, query)
    }

    /// Resolve an input string to a bang's URL, or nil if it isn't a bang.
    static func resolve(_ input: String) -> URL? {
        guard enabled, let (bang, query) = split(input) else { return nil }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return URL(string: bang.home) }
        let q = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
        return URL(string: bang.template.replacingOccurrences(of: "%@", with: q))
    }

    struct Suggestion {
        let bang: Bang
        let url: URL
    }

    /// Bang suggestions for the omnibox dropdown. If the input already names a
    /// full bang, only that one (applied to the query) is returned; otherwise
    /// the bare `!prefix` lists matching triggers to complete. Empty when the
    /// input has no `!token`.
    static func suggestions(for input: String, limit: Int = 5) -> [Suggestion] {
        guard enabled else { return [] }
        let words = input.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let idx = words.firstIndex(where: { $0.hasPrefix("!") }) else { return [] }
        let prefix = String(words[idx].dropFirst()).lowercased()
        let query = words.enumerated().filter { $0.offset != idx }.map { $0.element }.joined(separator: " ")
        let trimmed = query.trimmingCharacters(in: .whitespaces)

        // Exact trigger → just that bang (applied to the query).
        let pool: [Bang]
        if let exact = byTrigger[prefix] {
            pool = [exact]
        } else {
            pool = all.filter { $0.trigger.hasPrefix(prefix) }.sorted { $0.trigger.count < $1.trigger.count }
        }
        return pool.prefix(limit).compactMap { bang in
            let url: URL?
            if trimmed.isEmpty {
                url = URL(string: bang.home)
            } else {
                let q = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
                url = URL(string: bang.template.replacingOccurrences(of: "%@", with: q))
            }
            return url.map { Suggestion(bang: bang, url: $0) }
        }
    }
}
