import Foundation
import SQLite3
import Testing
@testable import ChromelessCore

@Suite("Database — schema and migration")
struct DatabaseTests {

    private func schemaObjects(in db: DB) -> Set<String> {
        var out = Set<String>()
        guard let stmt = db.prepare("SELECT name FROM sqlite_master WHERE type IN ('table', 'trigger');") else {
            return out
        }
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.insert(String(cString: sqlite3_column_text(stmt, 0)))
        }
        sqlite3_finalize(stmt)
        return out
    }

    @Test("migrations create the full schema")
    func schema() {
        let objects = schemaObjects(in: DB.inMemory())
        for name in ["history_items", "visits", "history_fts", "identities", "site_bindings",
                     "history_ai", "history_au", "history_ad"] {
            #expect(objects.contains(name), "missing schema object \(name)")
        }
    }

    @Test("Migrations are idempotent and data survives a reopen")
    func idempotent() {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("chromeless-dbtest-\(UUID().uuidString).sqlite").path
        defer {
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: path + "-wal")
            try? FileManager.default.removeItem(atPath: path + "-shm")
        }

        do {
            let url = URL(string: "https://example.com")!
            let store = HistoryStore(db: DB(path: path))
            store.recordVisit(url: url, title: "Example")
        }

        // A second open re-runs migrate() (IF NOT EXISTS everywhere) and must
        // find the row written by the first session.
        let reopened = HistoryStore(db: DB(path: path))
        let recent = reopened.recentItems()
        #expect(recent.count == 1)
        #expect(recent[0].url == URL(string: "https://example.com")!.absoluteString)
        #expect(recent[0].title == "Example")
    }
}