import Foundation
import Testing
@testable import ChromelessCore

@Suite("SearchEngine — templates, preferences, suggest parsing")
struct SearchEngineTests {

    @Test("Every engine has a query and suggest template with a %@ slot")
    func templates() {
        for engine in SearchEngine.allCases {
            #expect(engine.queryTemplate.contains("%@"))
            #expect(engine.suggestTemplate.contains("%@"))
            #expect(!engine.label.isEmpty)
        }
    }

    @Test("searchURL percent-encodes the query into the template")
    func searchURL() {
        let url = SearchEngine.google.searchURL(for: "swift testing")
        #expect(url?.absoluteString == "https://www.google.com/search?q=swift%20testing")

        let special = SearchEngine.duckduckgo.searchURL(for: "a&b=c")
        #expect(special?.absoluteString == "https://duckduckgo.com/?q=a&b=c"
                || special?.absoluteString == "https://duckduckgo.com/?q=a%26b%3Dc")
    }

    @Test("current defaults to Google when no preference is set")
    func currentDefault() {
        withIsolatedSeams {
            #expect(SearchEngine.current == .google)
        }
    }

    @Test("current follows the stored preference and falls back on garbage")
    func currentOverride() {
        withIsolatedSeams {
            SearchEngine.defaults.set("brave", forKey: "DefaultSearchEngine")
            #expect(SearchEngine.current == .brave)

            SearchEngine.defaults.set("not-an-engine", forKey: "DefaultSearchEngine")
            #expect(SearchEngine.current == .google)
        }
    }

    @Test("Suggestions are enabled by default and toggleable")
    func suggestionsFlag() {
        withIsolatedSeams {
            #expect(SearchEngine.suggestionsEnabled)
            SearchEngine.defaults.set(false, forKey: "SearchSuggestions")
            #expect(!SearchEngine.suggestionsEnabled)
        }
    }

    @Test("parse accepts the OpenSearch [query, [suggestions…]] shape")
    func parseValid() throws {
        let json = Data(#"["cats", ["cats", "cats movie", "cats musical"], {"k": 1}]"#.utf8)
        let phrases = try #require(SearchSuggest.parse(json))
        #expect(phrases == ["cats", "cats movie", "cats musical"])
    }

    @Test("parse tolerates non-string entries in the suggestion list")
    func parseMixedTypes() throws {
        let json = Data(#"["q", ["good", 42, null, "also good"]]"#.utf8)
        let phrases = try #require(SearchSuggest.parse(json))
        #expect(phrases == ["good", "also good"])
    }

    @Test("parse rejects malformed or wrong-shaped JSON")
    func parseInvalid() {
        #expect(SearchSuggest.parse(Data("not json".utf8)) == nil)
        #expect(SearchSuggest.parse(Data(#"["only-query"]"#.utf8)) == nil)
        #expect(SearchSuggest.parse(Data(#"["q", "not-a-list"]"#.utf8)) == nil)
        #expect(SearchSuggest.parse(Data("{}".utf8)) == nil)
    }
}
