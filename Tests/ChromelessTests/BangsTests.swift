import Foundation
import Testing
@testable import ChromelessCore

@Suite("Bangs — !trigger resolution and suggestions")
struct BangsTests {

    @Test("Bang at the start of the input resolves")
    func bangAtStart() {
        withIsolatedSeams {
            #expect(Bangs.resolve("!w cats")?.absoluteString
                    == "https://en.wikipedia.org/w/index.php?search=cats")
        }
    }

    @Test("Bang after or between words still resolves")
    func bangAnywhere() {
        withIsolatedSeams {
            let trailing = Bangs.resolve("cats !w")
            #expect(trailing?.absoluteString == "https://en.wikipedia.org/w/index.php?search=cats")

            let middle = Bangs.resolve("find !w cats")
            #expect(middle?.absoluteString == "https://en.wikipedia.org/w/index.php?search=find%20cats")
        }
    }

    @Test("Triggers are case-insensitive")
    func caseInsensitive() {
        withIsolatedSeams {
            #expect(Bangs.resolve("!W cats") == Bangs.resolve("!w cats"))
        }
    }

    @Test("Empty query navigates to the engine's home page")
    func emptyQueryGoesHome() {
        withIsolatedSeams {
            #expect(Bangs.resolve("!w")?.absoluteString == "https://en.wikipedia.org")
            #expect(Bangs.resolve("!g")?.absoluteString == "https://www.google.com")
        }
    }

    @Test("Queries are percent-encoded")
    func percentEncoding() {
        withIsolatedSeams {
            #expect(Bangs.resolve("!g hello world")?.absoluteString
                    == "https://www.google.com/search?q=hello%20world")
        }
    }

    @Test("Unknown triggers and bang-less input return nil")
    func noBang() {
        withIsolatedSeams {
            #expect(Bangs.resolve("!notarealbang cats") == nil)
            #expect(Bangs.resolve("just a search") == nil)
            #expect(Bangs.resolve("!") == nil) // "!" alone is not a token
        }
    }

    @Test("Disabling bangs turns resolution and suggestions off")
    func disabledFlag() {
        withIsolatedSeams {
            Bangs.defaults.set(false, forKey: "BangsEnabled")
            #expect(!Bangs.enabled)
            #expect(Bangs.resolve("!w cats") == nil)
            #expect(Bangs.suggestions(for: "!w").isEmpty)
        }
    }

    @Test("Exact trigger suggests only that bang")
    func suggestionExact() {
        withIsolatedSeams {
            let s = Bangs.suggestions(for: "!w cats")
            #expect(s.count == 1)
            #expect(s.first?.bang.trigger == "w")
            #expect(s.first?.url.absoluteString == "https://en.wikipedia.org/w/index.php?search=cats")
        }
    }

    @Test("Prefix lists matching triggers, shortest first")
    func suggestionPrefix() {
        withIsolatedSeams {
            let s = Bangs.suggestions(for: "!c", limit: 5)
            let triggers = s.map(\.bang.trigger)
            #expect(triggers.contains("claude"))
            #expect(triggers.contains("chatgpt"))
            // Shorter trigger sorts first.
            #expect(triggers.firstIndex(of: "claude")! < triggers.firstIndex(of: "chatgpt")!)
            // Empty query → suggestions point at home pages.
            #expect(s.first { $0.bang.trigger == "claude" }?.url.absoluteString == "https://claude.ai")
        }
    }

    @Test("Suggestions respect the limit and require a !token")
    func suggestionLimits() {
        withIsolatedSeams {
            #expect(Bangs.suggestions(for: "hello").isEmpty)
            #expect(Bangs.suggestions(for: "!", limit: 3).count <= 3)
        }
    }

    @Test("Every bundled bang has a usable template and favicon host")
    func bundledBangsAreWellFormed() {
        for bang in Bangs.all {
            #expect(!bang.trigger.isEmpty)
            #expect(bang.template.contains("%@"))
            #expect(bang.faviconHost != nil)
            #expect(URL(string: bang.home) != nil)
        }
        // Triggers must be unique or the byTrigger map silently drops one.
        let triggers = Bangs.all.map(\.trigger)
        #expect(Set(triggers).count == triggers.count)
    }
}
