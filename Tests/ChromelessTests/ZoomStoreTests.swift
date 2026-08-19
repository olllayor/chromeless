import Foundation
import Testing
@testable import ChromelessCore

@Suite("ZoomStore — per-site zoom persistence")
struct ZoomStoreTests {

    @Test("Defaults to 1.0 with no stored zoom")
    func defaultZoom() {
        withIsolatedSeams {
            #expect(ZoomStore.zoom(for: "example.com") == 1.0)
        }
    }

    @Test("Per-host zoom round-trips")
    func perHost() {
        withIsolatedSeams {
            ZoomStore.set(1.5, for: "example.com")
            #expect(ZoomStore.zoom(for: "example.com") == 1.5)
            #expect(ZoomStore.zoom(for: "other.com") == 1.0) // untouched host
        }
    }

    @Test("Setting 1.0 removes the stored entry (don't persist the default)")
    func resetToDefault() {
        withIsolatedSeams {
            ZoomStore.set(2.0, for: "example.com")
            ZoomStore.set(1.0, for: "example.com")
            #expect(ZoomStore.zoom(for: "example.com") == 1.0)
            let dict = ZoomStore.defaults.dictionary(forKey: "PerSiteZoom") as? [String: Double] ?? [:]
            #expect(dict["example.com"] == nil)
        }
    }

    @Test("A global DefaultZoom preference acts as the fallback")
    func globalDefault() {
        withIsolatedSeams {
            ZoomStore.defaults.set(1.25, forKey: "DefaultZoom")
            #expect(ZoomStore.zoom(for: "any.com") == 1.25)
            ZoomStore.set(0.8, for: "any.com")
            #expect(ZoomStore.zoom(for: "any.com") == 0.8) // per-host wins
        }
    }
}
