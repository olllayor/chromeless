import Foundation
import Testing
@testable import ChromelessCore

@Suite("ContentBlocker — rule list JSON and domain list")
struct ContentBlockerTests {

    @Test("buildJSON emits one third-party block rule per domain")
    func buildJSON() throws {
        let domains = ContentBlocker.domains
        #expect(!domains.isEmpty)
        let data = Data(ContentBlocker.buildJSON().utf8)
        guard let rules = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            Issue.record("buildJSON did not produce a JSON array of objects")
            return
        }
        #expect(rules.count == domains.count)
        for (domain, rule) in zip(domains, rules) {
            let esc = NSRegularExpression.escapedPattern(for: domain)
            let expectedFilter = "^https?://([^/]+\\.)?\(esc)"
            let trigger = rule["trigger"] as? [String: Any]
            #expect(trigger?["url-filter"] as? String == expectedFilter, "url-filter for \(domain)")
            #expect(trigger?["load-type"] as? [String] == ["third-party"])
            #expect((rule["action"] as? [String: Any])?["type"] as? String == "block")
        }
    }

    @Test("The domain list is well-formed and has no duplicates")
    func domainsWellFormed() {
        let domains = ContentBlocker.domains
        #expect(Set(domains).count == domains.count, "duplicate domains in the list")
        for d in domains {
            #expect(!d.isEmpty)
            #expect(!d.contains("/"), "domain has a path: \(d)")
            #expect(!d.contains(" "), "domain has whitespace: \(d)")
            #expect(!d.hasPrefix("."), "domain has a leading dot: \(d)")
            #expect(!d.hasSuffix("."), "domain has a trailing dot: \(d)")
            #expect(!d.hasPrefix("*"), "wildcards are not allowed: \(d)")
        }
    }
}