import Foundation
import Testing
@testable import ChromelessCore

@Suite("IdentityStore — CRUD, palette, ordering, site bindings, routing")
struct IdentityStoreTests {

    /// Builds a store whose WebKit data-store erase is stubbed out — tests must
    /// never drive WKWebsiteDataStore.remove in a headless test process.
    private func makeStore() -> IdentityStore {
        let store = IdentityStore(db: .inMemory())
        store.removeDataStore = { _ in }
        return store
    }

    @Test("A fresh store bootstraps exactly one default identity")
    func defaultBootstrap() {
        let store = makeStore()
        let all = store.all()
        #expect(all.count == 1)
        #expect(all[0].isDefault)
        #expect(all[0].id == IdentityStore.defaultID)
        #expect(all[0].name == "Personal")
        #expect(store.defaultIdentity.id == IdentityStore.defaultID)
    }

    @Test("create hands out palette colors round-robin and increments ordering")
    func create() {
        let store = makeStore()
        // The default identity occupiesies slot 0, so the first created identity
        // takes palette[1].
        let first = store.create(name: "Work")
        #expect(first.colorHex == IdentityStore.palette[1])
        #expect(first.ordering == 1)
        #expect(!first.isDefault)
        #expect(!first.ephemeral)

        let second = store.create(name: "Shopping", ephemeral: true)
        #expect(second.colorHex == IdentityStore.palette[2])
        #expect(second.ordering == 2)
        #expect(second.ephemeral)
    }

    @Test("all() lists the default first, then by ordering")
    func ordering() {
        let store = makeStore()
        store.create(name: "One")
        store.create(name: "Two")
        let names = store.all().map(\.name)
        #expect(names == ["Personal", "One", "Two"])
    }

    @Test("update persists edits and keeps the id stable")
    func update() {
        let store = makeStore()
        var identity = store.create(name: "Work")
        identity.name = "Job"
        identity.colorHex = "#000000"
        identity.emoji = "💼"
        store.update(identity)

        let reloaded = store.identity(identity.id)
        #expect(reloaded?.name == "Job")
        #expect(reloaded?.colorHex == "#000000")
        #expect(reloaded?.emoji == "💼")
    }

    @Test("delete removes the identity but never the default")
    func delete() {
        let store = IdentityStore(db: .inMemory())
        var removed: [UUID] = []
        store.removeDataStore = { removed.append($0) }

        let work = store.create(name: "Work")
        let temp = store.create(name: "Temp", ephemeral: true)

        store.delete(work)
        #expect(store.identity(work.id) == nil)
        // A persistent identity's on-disk container is erased via the hook…
        #expect(removed == [work.id])

        store.delete(temp)
        #expect(store.identity(temp.id) == nil)
        // …but an ephemeral one has nothing on disk, so the hook is skipped.
        #expect(removed == [work.id])

        store.delete(store.defaultIdentity)
        #expect(store.identity(IdentityStore.defaultID) != nil) // protected
        #expect(removed == [work.id]) // default never erased either
    }

    @Test("Deleting an identity cascades its site bindings")
    func deleteCascadesBindings() {
        let store = makeStore()
        let work = store.create(name: "Work")
        store.setBinding(host: "mail.google.com", identityID: work.id)
        #expect(store.binding(forHost: "mail.google.com") == work.id)

        store.delete(work)
        #expect(store.binding(forHost: "mail.google.com") == nil)
    }

    @Test("setBinding upserts and nil deletes")
    func bindings() {
        let store = makeStore()
        let a = store.create(name: "A")
        let b = store.create(name: "B")

        store.setBinding(host: "github.com", identityID: a.id)
        #expect(store.binding(forHost: "github.com") == a.id)

        store.setBinding(host: "github.com", identityID: b.id) // upsert
        #expect(store.binding(forHost: "github.com") == b.id)

        store.setBinding(host: "github.com", identityID: nil) // delete
        #expect(store.binding(forHost: "github.com") == nil)
        #expect(store.allBindings().isEmpty)
    }

    // MARK: registrableDomain (pure eTLD+1 approximation)

    @Test("registrableDomain collapses subdomains to eTLD+1")
    func registrableDomain() {
        #expect(IdentityStore.registrableDomain("mail.google.com") == "google.com")
        #expect(IdentityStore.registrableDomain("a.b.c.example.com") == "example.com")
        #expect(IdentityStore.registrableDomain("GOOGLE.COM") == "google.com")
    }

    @Test("registrableDomain keeps known two-level TLDs intact")
    func registrableDomainTwoLevel() {
        #expect(IdentityStore.registrableDomain("bbc.co.uk") == "bbc.co.uk")
        #expect(IdentityStore.registrableDomain("news.bbc.co.uk") == "bbc.co.uk")
        #expect(IdentityStore.registrableDomain("shop.example.com.au") == "example.com.au")
    }

    @Test("registrableDomain returns short hosts unchanged")
    func registrableDomainShort() {
        #expect(IdentityStore.registrableDomain("localhost") == "localhost")
        #expect(IdentityStore.registrableDomain("example.com") == "example.com")
    }

    // MARK: Routing

    @Test("routedIdentity prefers an exact host binding")
    func routingExact() {
        let store = makeStore()
        let work = store.create(name: "Work")
        store.setBinding(host: "mail.google.com", identityID: work.id)
        #expect(store.routedIdentity(forHost: "mail.google.com") == work.id)
    }

    @Test("routedIdentity falls back to a same-registrable-domain binding")
    func routingDomainFallback() {
        let store = makeStore()
        let work = store.create(name: "Work")
        store.setBinding(host: "mail.google.com", identityID: work.id)
        // A navigation to another subdomain of the same site follows the rule.
        #expect(store.routedIdentity(forHost: "accounts.google.com") == work.id)
        // An unrelated host routes nowhere.
        #expect(store.routedIdentity(forHost: "example.org") == nil)
    }

    // MARK: Identity value type

    @Test("initial prefers the emoji, else the uppercased first letter")
    func initial() {
        let base = Identity(id: UUID(), name: "work", colorHex: "#000",
                            emoji: nil, googleEmail: nil, isDefault: false,
                            ephemeral: false, ordering: 0)
        #expect(base.initial == "W")
        var withEmoji = base
        withEmoji.emoji = "💼"
        #expect(withEmoji.initial == "💼")
        var empty = base
        empty.name = ""
        #expect(empty.initial == "?")
    }
}
