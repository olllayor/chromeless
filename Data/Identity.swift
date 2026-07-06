import Cocoa
import WebKit
import SQLite3

// MARK: - Identities (per-tab account containers)
//
// An identity is an account container: a name, a color, an avatar glyph, and —
// crucially — its own isolated cookie/storage jar (WKWebsiteDataStore). Two tabs
// on different identities can be signed into two different Gmail accounts at the
// same time, in the same window. See plan/accounts.md.

struct Identity: Equatable {
    let id: UUID
    var name: String
    var colorHex: String
    var emoji: String?          // avatar glyph until a Google avatar is linked
    var googleEmail: String?    // optional linked account
    var isDefault: Bool
    var ephemeral: Bool         // in-memory (nonPersistent) store; cleared on app quit
    var ordering: Int

    var color: NSColor { NSColor(hex: colorHex) ?? .systemBlue }

    /// The single character shown in the avatar chip when no emoji is set.
    var initial: String {
        if let e = emoji, !e.isEmpty { return e }
        return String(name.first.map(String.init) ?? "?").uppercased()
    }
}

final class IdentityStore {
    static let shared = IdentityStore()
    private let db = DB.shared

    /// Fixed id for the built-in default identity. Its data store is the shared
    /// `.default()` jar, so upgrading users keep every existing session.
    static let defaultID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    /// Palette handed out (round-robin) to freshly created identities.
    static let palette = ["#3B82F6", "#10B981", "#F59E0B", "#EF4444",
                          "#8B5CF6", "#EC4899", "#14B8A6", "#F97316"]

    /// Live data stores keyed by identity id. Vended lazily and cached for the
    /// process lifetime so every tab of one identity shares exactly one jar.
    private var stores: [UUID: WKWebsiteDataStore] = [:]

    private init() {
        ensureDefault()
    }

    // MARK: Data store vending

    /// The isolated (or, for the default identity, shared) data store backing an
    /// identity. Cached: repeated calls return the same instance.
    func dataStore(for identity: Identity) -> WKWebsiteDataStore {
        if let s = stores[identity.id] { return s }
        let store: WKWebsiteDataStore
        if identity.isDefault {
            store = .default()
        } else if identity.ephemeral {
            store = .nonPersistent()
        } else if #available(macOS 14.0, *) {
            store = WKWebsiteDataStore(forIdentifier: identity.id)
        } else {
            // macOS 13 has no public per-identity persistent store; degrade to an
            // isolated in-memory jar (lost on quit). Warned once in the UI.
            store = .nonPersistent()
        }
        stores[identity.id] = store
        return store
    }

    func dataStore(forID id: UUID) -> WKWebsiteDataStore {
        dataStore(for: identity(id) ?? defaultIdentity)
    }

    /// Erase all website data for an identity's persistent store (macOS 14+).
    /// No-op for ephemeral / default-on-13 stores, which have nothing on disk.
    func wipeData(for identity: Identity, completion: (() -> Void)? = nil) {
        let store = dataStore(for: identity)
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                         modifiedSince: Date(timeIntervalSince1970: 0)) { completion?() }
    }

    // MARK: Queries

    var defaultIdentity: Identity {
        identity(Self.defaultID) ?? Identity(
            id: Self.defaultID, name: "Personal", colorHex: "#3B82F6", emoji: nil,
            googleEmail: nil, isDefault: true, ephemeral: false, ordering: 0)
    }

    func identity(_ id: UUID) -> Identity? {
        all().first { $0.id == id }
    }

    func all() -> [Identity] {
        guard let stmt = db.prepare(
            "SELECT id, name, color, emoji, google_email, is_default, ephemeral, ordering " +
            "FROM identities ORDER BY is_default DESC, ordering ASC, created ASC;"
        ) else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [Identity] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idStr = sqlite3_column_text(stmt, 0),
                  let id = UUID(uuidString: String(cString: idStr)) else { continue }
            let name = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let color = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? "#3B82F6"
            let emoji = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
            let email = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
            out.append(Identity(
                id: id, name: name, colorHex: color,
                emoji: (emoji?.isEmpty == true) ? nil : emoji,
                googleEmail: (email?.isEmpty == true) ? nil : email,
                isDefault: sqlite3_column_int(stmt, 5) != 0,
                ephemeral: sqlite3_column_int(stmt, 6) != 0,
                ordering: Int(sqlite3_column_int(stmt, 7))))
        }
        return out
    }

    // MARK: Mutations

    @discardableResult
    func create(name: String, colorHex: String? = nil, emoji: String? = nil,
                ephemeral: Bool = false) -> Identity {
        let existing = all()
        let color = colorHex ?? Self.palette[existing.count % Self.palette.count]
        let ordering = (existing.map(\.ordering).max() ?? 0) + 1
        let identity = Identity(
            id: UUID(), name: name, colorHex: color, emoji: emoji,
            googleEmail: nil, isDefault: false, ephemeral: ephemeral, ordering: ordering)
        upsert(identity)
        return identity
    }

    /// Persist edits (name/color/emoji/linked email). The data store is keyed by
    /// id, which never changes, so the cached jar and any live tabs are untouched.
    func update(_ identity: Identity) {
        upsert(identity)
    }

    /// Delete an identity and (macOS 14+) its on-disk data. The default identity
    /// can't be deleted. Bindings cascade. Callers must first migrate/close any
    /// open tabs on it (handled by the window layer).
    func delete(_ identity: Identity) {
        guard !identity.isDefault else { return }
        stores.removeValue(forKey: identity.id)
        if let stmt = db.prepare("DELETE FROM identities WHERE id = ?;") {
            bind(stmt, 1, identity.id.uuidString)
            sqlite3_step(stmt); sqlite3_finalize(stmt)
        }
        // Erase the on-disk container, but only after the current runloop turn so
        // the just-closed tabs' web-content processes have released the store
        // (removing an in-use store is a no-op). `remove` also wipes the data, so
        // no separate wipeData call is needed.
        if #available(macOS 14.0, *), !identity.ephemeral {
            let uid = identity.id
            DispatchQueue.main.async { WKWebsiteDataStore.remove(forIdentifier: uid) { _ in } }
        }
    }

    private func upsert(_ i: Identity) {
        guard let stmt = db.prepare("""
            INSERT INTO identities (id, name, color, emoji, google_email, is_default, ephemeral, ordering, created)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name=excluded.name, color=excluded.color, emoji=excluded.emoji,
                google_email=excluded.google_email, ephemeral=excluded.ephemeral,
                ordering=excluded.ordering;
        """) else { return }
        bind(stmt, 1, i.id.uuidString)
        bind(stmt, 2, i.name)
        bind(stmt, 3, i.colorHex)
        bind(stmt, 4, i.emoji ?? "")
        bind(stmt, 5, i.googleEmail ?? "")
        sqlite3_bind_int(stmt, 6, i.isDefault ? 1 : 0)
        sqlite3_bind_int(stmt, 7, i.ephemeral ? 1 : 0)
        sqlite3_bind_int(stmt, 8, Int32(i.ordering))
        sqlite3_bind_double(stmt, 9, Date().timeIntervalSince1970)
        sqlite3_step(stmt); sqlite3_finalize(stmt)
    }

    /// Create the default identity row on first launch if it doesn't exist.
    private func ensureDefault() {
        if identity(Self.defaultID) != nil { return }
        guard let stmt = db.prepare("""
            INSERT OR IGNORE INTO identities
            (id, name, color, emoji, google_email, is_default, ephemeral, ordering, created)
            VALUES (?, 'Personal', '#3B82F6', NULL, NULL, 1, 0, 0, ?);
        """) else { return }
        bind(stmt, 1, Self.defaultID.uuidString)
        sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
        sqlite3_step(stmt); sqlite3_finalize(stmt)
    }

    // MARK: Site bindings (P3 — populated later, read here so routing can ship)

    // A few common two-level public suffixes so `registrableDomain` doesn't
    // collapse e.g. bbc.co.uk to co.uk. Not exhaustive (no full PSL), just the
    // ones people routinely sign into.
    private static let twoLevelTLDs: Set<String> = [
        "co.uk", "org.uk", "gov.uk", "ac.uk", "co.jp", "com.au", "net.au",
        "org.au", "co.nz", "co.in", "co.kr", "com.br", "com.mx", "com.tr"]

    /// Approximate registrable domain (eTLD+1). `mail.google.com` → `google.com`,
    /// `bbc.co.uk` → `bbc.co.uk`. Used so a rule for one host of a site also
    /// covers the site's auth/other subdomains (e.g. accounts.google.com).
    func registrableDomain(_ host: String) -> String {
        let labels = host.lowercased().split(separator: ".").map(String.init)
        guard labels.count > 2 else { return host.lowercased() }
        let lastTwo = labels.suffix(2).joined(separator: ".")
        if Self.twoLevelTLDs.contains(lastTwo) { return labels.suffix(3).joined(separator: ".") }
        return lastTwo
    }

    /// The identity a navigation to `host` should be routed into: an exact host
    /// binding first, else any binding sharing the same registrable domain (so a
    /// site's login subdomains follow it into the same container).
    func routedIdentity(forHost host: String) -> UUID? {
        if let id = binding(forHost: host) { return id }
        let domain = registrableDomain(host)
        return allBindings().first { registrableDomain($0.host) == domain }?.identityID
    }

    /// The identity a host is pinned to, if any.
    func binding(forHost host: String) -> UUID? {
        guard let stmt = db.prepare("SELECT identity_id FROM site_bindings WHERE host = ?;") else { return nil }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, host)
        guard sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) else { return nil }
        return UUID(uuidString: String(cString: c))
    }

    /// All host → identity routing rules, host-sorted.
    func allBindings() -> [(host: String, identityID: UUID)] {
        guard let stmt = db.prepare(
            "SELECT host, identity_id FROM site_bindings ORDER BY host ASC;") else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [(host: String, identityID: UUID)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let h = sqlite3_column_text(stmt, 0), let i = sqlite3_column_text(stmt, 1),
                  let uid = UUID(uuidString: String(cString: i)) else { continue }
            out.append((host: String(cString: h), identityID: uid))
        }
        return out
    }

    func setBinding(host: String, identityID: UUID?) {
        if let identityID {
            if let stmt = db.prepare(
                "INSERT INTO site_bindings (host, identity_id) VALUES (?, ?) " +
                "ON CONFLICT(host) DO UPDATE SET identity_id=excluded.identity_id;") {
                bind(stmt, 1, host); bind(stmt, 2, identityID.uuidString)
                sqlite3_step(stmt); sqlite3_finalize(stmt)
            }
        } else if let stmt = db.prepare("DELETE FROM site_bindings WHERE host = ?;") {
            bind(stmt, 1, host); sqlite3_step(stmt); sqlite3_finalize(stmt)
        }
    }

    // SQLite text binding needs SQLITE_TRANSIENT so it copies the Swift string.
    private func bind(_ stmt: OpaquePointer?, _ idx: Int32, _ value: String) {
        sqlite3_bind_text(stmt, idx, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
}
