import Cocoa
import CoreLocation
import LocalAuthentication
import Security
import WebKit

// MARK: - Search engine

enum SearchEngine: String, CaseIterable {
    case google, duckduckgo, brave

    var label: String {
        switch self {
        case .google: return "Google"
        case .duckduckgo: return "DuckDuckGo"
        case .brave: return "Brave Search"
        }
    }

    /// Query template; `%@` is replaced with the percent-encoded query.
    var queryTemplate: String {
        switch self {
        case .google: return "https://www.google.com/search?q=%@"
        case .duckduckgo: return "https://duckduckgo.com/?q=%@"
        case .brave: return "https://search.brave.com/search?q=%@"
        }
    }

    /// OpenSearch suggest endpoint; `%@` is the percent-encoded query. Each
    /// returns the two-element JSON array `[query, [suggestions…]]`.
    var suggestTemplate: String {
        switch self {
        case .google: return "https://suggestqueries.google.com/complete/search?client=firefox&q=%@"
        case .duckduckgo: return "https://duckduckgo.com/ac/?type=list&q=%@"
        case .brave: return "https://search.brave.com/api/suggest?q=%@"
        }
    }

    static var current: SearchEngine {
        SearchEngine(rawValue: UserDefaults.standard.string(forKey: "DefaultSearchEngine") ?? "") ?? .google
    }

    /// Whether the address bar sends keystrokes to the engine for suggestions.
    /// Helium-style default: on.
    static var suggestionsEnabled: Bool {
        UserDefaults.standard.object(forKey: "SearchSuggestions") as? Bool ?? true
    }

    /// Results-page URL for a finished query string.
    func searchURL(for query: String) -> URL? {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        return URL(string: queryTemplate.replacingOccurrences(of: "%@", with: q))
    }
}

// MARK: - Search suggestions

/// Fetches address-bar suggestions from the default engine's OpenSearch
/// suggest endpoint. No-ops (empty result) when suggestions are disabled.
enum SearchSuggest {
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 4
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    /// Calls `completion` on the main queue with up to a handful of phrases.
    /// Silent on any failure — suggestions are best-effort.
    static func fetch(_ query: String, completion: @escaping ([String]) -> Void) {
        guard SearchEngine.suggestionsEnabled else { completion([]); return }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2,
              let q = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: SearchEngine.current.suggestTemplate.replacingOccurrences(of: "%@", with: q))
        else { completion([]); return }

        session.dataTask(with: url) { data, _, _ in
            let phrases = data.flatMap(parse) ?? []
            DispatchQueue.main.async { completion(phrases) }
        }.resume()
    }

    /// Parses `[query, [suggestions…]]`. Trailing metadata elements ignored.
    private static func parse(_ data: Data) -> [String]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [Any],
              root.count >= 2, let list = root[1] as? [Any] else { return nil }
        return list.compactMap { $0 as? String }
    }
}
