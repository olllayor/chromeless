import Cocoa
import CoreLocation
import LocalAuthentication
import Security
import WebKit

// MARK: - Storage

import SQLite3

final class DB {
    static let shared = DB()
    private var db: OpaquePointer?

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Chromeless", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("chromeless.sqlite").path
        if sqlite3_open(path, &db) != SQLITE_OK {
            fputs("chromeless: failed to open database\n", stderr)
        }
        migrate()
    }

    private func migrate() {
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA foreign_keys=ON;")
        exec("""
        CREATE TABLE IF NOT EXISTS history_items (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            url TEXT NOT NULL UNIQUE,
            title TEXT,
            host TEXT NOT NULL,
            visit_count INTEGER DEFAULT 0,
            last_visit REAL NOT NULL
        );
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS visits (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            history_item_id INTEGER REFERENCES history_items(id) ON DELETE CASCADE,
            visit_time REAL NOT NULL
        );
        """)
        exec("""
        CREATE VIRTUAL TABLE IF NOT EXISTS history_fts USING fts5(
            url, title, content='history_items', content_rowid='id', tokenize='porter unicode61'
        );
        """)
        exec("CREATE TRIGGER IF NOT EXISTS history_ai AFTER INSERT ON history_items BEGIN INSERT INTO history_fts(rowid, url, title) VALUES (new.id, new.url, new.title); END;")
        exec("CREATE TRIGGER IF NOT EXISTS history_ad AFTER DELETE ON history_items BEGIN INSERT INTO history_fts(history_fts, rowid, url, title) VALUES('delete', old.id, old.url, old.title); END;")
        exec("CREATE TRIGGER IF NOT EXISTS history_au AFTER UPDATE ON history_items BEGIN INSERT INTO history_fts(history_fts, rowid, url, title) VALUES('delete', old.id, old.url, old.title); INSERT INTO history_fts(rowid, url, title) VALUES (new.id, new.url, new.title); END;")

        // Identities — per-tab account containers (see plan/accounts.md). Each
        // row owns an isolated WKWebsiteDataStore; the default row reuses the
        // shared jar so existing sessions survive with no migration.
        exec("""
        CREATE TABLE IF NOT EXISTS identities (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            color TEXT NOT NULL,
            emoji TEXT,
            google_email TEXT,
            is_default INTEGER DEFAULT 0,
            ephemeral INTEGER DEFAULT 0,
            ordering INTEGER DEFAULT 0,
            created REAL NOT NULL
        );
        """)
        // Host → identity routing rules: a navigation to a bound host is forked
        // into a tab of that identity (P3). CASCADE so deleting an identity
        // drops its bindings.
        exec("""
        CREATE TABLE IF NOT EXISTS site_bindings (
            host TEXT PRIMARY KEY,
            identity_id TEXT NOT NULL REFERENCES identities(id) ON DELETE CASCADE
        );
        """)
    }

    func exec(_ sql: String) {
        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
            if let msg = errMsg { fputs("chromeless: SQL error: \(String(cString: msg))\n", stderr) }
            sqlite3_free(errMsg)
        }
    }

    func prepare(_ sql: String) -> OpaquePointer? {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            if let err = sqlite3_errmsg(db) {
                fputs("chromeless: prepare error: \(String(cString: err))\n", stderr)
            }
            return nil
        }
        return stmt
    }

    deinit {
        sqlite3_close(db)
    }
}
