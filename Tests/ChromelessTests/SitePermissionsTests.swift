import Foundation
import Testing
@testable import ChromelessCore

@Suite("SitePermissions — origin keys and per-site decisions")
struct SitePermissionsTests {

    @Test("origin(for:) requires an http(s) scheme and a host")
    func originFromURL() {
        #expect(SitePermissionStore.origin(for: URL(string: "https://example.com/a?b=1")) == "https://example.com")
        #expect(SitePermissionStore.origin(for: URL(string: "http://localhost:8080")) == "http://localhost")
        #expect(SitePermissionStore.origin(for: URL(string: "HTTPS://example.com")) == "https://example.com")
        #expect(SitePermissionStore.origin(for: URL(string: "file:///tmp/x")) == nil)
        #expect(SitePermissionStore.origin(for: URL(string: "chromeless://settings")) == nil)
        #expect(SitePermissionStore.origin(for: URL(string: "https://")) == nil)
        #expect(SitePermissionStore.origin(for: nil) == nil)
    }

    // NOTE: the WKSecurityOrigin overload of origin(for:) is not exercised
    // directly — WebKit exposes no public initializer for WKSecurityOrigin, so
    // tests can't fabricate one. It applies the same scheme/host rules as the
    // URL overload above.

    @Test("decisions round-trip and persist across instances")
    func roundTrip() {
        withDefaults { defaults in
            let store = SitePermissionStore(defaults: defaults)
            #expect(store.decision("https://a.com", .camera) == .ask)
            store.set("https://a.com", .camera, .allow)
            #expect(store.decision("https://a.com", .camera) == .allow)
            #expect(store.decision("https://a.com", .microphone) == .ask)
            #expect(store.origins() == ["https://a.com"])
            let reloaded = SitePermissionStore(defaults: defaults)
            #expect(reloaded.decision("https://a.com", .camera) == .allow)
        }
    }

    @Test("Setting .ask removes the decision; the origin vanishes when nothing remains")
    func askRemoves() {
        withDefaults { defaults in
            let store = SitePermissionStore(defaults: defaults)
            store.set("https://a.com", .camera, .deny)
            store.set("https://a.com", .microphone, .allow)
            store.set("https://a.com", .camera, .ask)
            #expect(store.decision("https://a.com", .camera) == .ask)
            #expect(store.origins() == ["https://a.com"]) // microphone still set
            store.set("https://a.com", .microphone, .ask)
            #expect(store.origins().isEmpty)
        }
    }

    @Test("reset forgets one origin; clearAll forgets every origin")
    func resetAndClear() {
        withDefaults { defaults in
            let store = SitePermissionStore(defaults: defaults)
            store.set("https://a.com", .camera, .allow)
            store.set("https://b.com", .microphone, .deny)
            store.reset("https://a.com")
            #expect(store.decision("https://a.com", .camera) == .ask)
            #expect(store.decision("https://b.com", .microphone) == .deny)
            store.clearAll()
            #expect(store.origins().isEmpty)
        }
    }
}