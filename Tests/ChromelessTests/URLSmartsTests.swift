import Foundation
import Testing
@testable import ChromelessCore

@Suite("smartURL — omnibox input classification")
struct URLSmartsTests {

    @Test("Empty and whitespace-only input yields nil")
    func emptyInput() {
        #expect(smartURL("") == nil)
        #expect(smartURL("   \n\t ") == nil)
    }

    @Test("Explicit scheme is used verbatim")
    func explicitScheme() {
        #expect(smartURL("https://example.com/x")?.absoluteString == "https://example.com/x")
        #expect(smartURL("http://example.com")?.absoluteString == "http://example.com")
        #expect(smartURL("chromeless://settings")?.absoluteString == "chromeless://settings")
    }

    @Test("Existing absolute path becomes a file URL")
    func absoluteFilePath() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("chromeless-urltest-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: path.path, contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(at: path) }

        let url = smartURL(path.path)
        #expect(url?.isFileURL == true)
        #expect(url?.path == path.path)
    }

    @Test("Missing path falls through to search/URL heuristics")
    func missingPathFallsThrough() {
        // No dot, no scheme → search query fallback.
        let url = withIsolatedSeams { smartURL("/definitely/not/here-xyz") }
        #expect(url?.host == "www.google.com")
    }

    @Test("Loopback hosts get an http:// scheme")
    func localhost() {
        #expect(smartURL("localhost:3000")?.absoluteString == "http://localhost:3000")
        #expect(smartURL("127.0.0.1:8080")?.absoluteString == "http://127.0.0.1:8080")
        #expect(smartURL("[::1]:5173")?.absoluteString == "http://[::1]:5173")
        #expect(smartURL("localhost")?.absoluteString == "http://localhost")
    }

    @Test("Domain-like input (dot, no spaces) becomes https")
    func domainLike() {
        #expect(smartURL("example.com")?.absoluteString == "https://example.com")
        #expect(smartURL("sub.example.co.uk/path?q=1")?.absoluteString == "https://sub.example.co.uk/path?q=1")
    }

    @Test("Input with spaces becomes a search URL for the current engine")
    func searchFallback() {
        withIsolatedSeams {
            #expect(SearchEngine.current == .google)
            let url = smartURL("hello world")
            #expect(url?.absoluteString == "https://www.google.com/search?q=hello%20world")
        }
    }

    @Test("Search fallback follows the configured engine")
    func searchFallbackFollowsEngine() {
        withIsolatedSeams {
            SearchEngine.defaults.set("duckduckgo", forKey: "DefaultSearchEngine")
            let url = smartURL("swift testing")
            #expect(url?.absoluteString == "https://duckduckgo.com/?q=swift%20testing")
        }
    }

    @Test("Bang input resolves before search classification")
    func bangPrecedence() {
        withIsolatedSeams {
            let url = smartURL("!w cats")
            #expect(url?.absoluteString == "https://en.wikipedia.org/w/index.php?search=cats")
        }
    }
}
