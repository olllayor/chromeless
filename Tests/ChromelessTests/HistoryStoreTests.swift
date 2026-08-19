import Foundation
import SQLite3
import Testing
@testable import ChromelessCore

@Suite("HistoryStore — visit recording, FTS search, paging, deletion")
struct HistoryStoreTests {

    private func makeStore() -> (HistoryStore, DB) {
        let db = DB.inMemory()
        return (HistoryStore(db: db), db)
    }

    @Test("recordVisit inserts a row with host and visit count")
    func recordVisit() {
        let (store, _) = makeStore()
        store.recordVisit(url: URL(string: "https://example.com/a")!, title: "Example")

        let entries = store.entries()
        #expect(entries.count == 1)
        #expect(entries[0].url == "https://example.com/a")
        #expect(entries[0].title == "Example")
    }

    @Test("Revisiting increments the visit count and keeps the better title")
    func revisit() {
        let (store, db) = makeStore()
        store.recordVisit(url: URL(string: "https://example.com")!, title: "Good Title")
        // A revisit whose title arrived empty must not wipe the stored title.
        store.recordVisit(url: URL(string: "https://example.com")!, title: "")

        var count = 0
        if let stmt = db.prepare("SELECT visit_count, title FROM history_items;") {
            if sqlite3_step(stmt) == SQLITE_ROW {
                count = Int(sqlite3_column_int(stmt, 0))
                #expect(String(cString: sqlite3_column_text(stmt, 1)) == "Good Title")
            }
            sqlite3_finalize(stmt)
        }
        #expect(count == 2)

        // A later non-empty title does replace it.
        store.recordVisit(url: URL(string: "https://example.com")!, title: "Newer")
        #expect(store.entries()[0].title == "Newer")
    }

    @Test("URLs without a host are not recorded")
    func noHostIgnored() {
        let (store, _) = makeStore()
        store.recordVisit(url: URL(string: "about:blank")!, title: nil)
        #expect(store.entries().isEmpty)
    }

    @Test("Each visit also lands in the visits table")
    func visitsTable() {
        let (store, db) = makeStore()
        store.recordVisit(url: URL(string: "https://example.com")!, title: nil)
        store.recordVisit(url: URL(string: "https://example.com")!, title: nil)

        var visits = 0
        if let stmt = db.prepare("SELECT COUNT(*) FROM visits;") {
            if sqlite3_step(stmt) == SQLITE_ROW { visits = Int(sqlite3_column_int(stmt, 0)) }
            sqlite3_finalize(stmt)
        }
        #expect(visits == 2)
    }

    @Test("search matches on title and URL prefixes")
    func search() {
        let (store, _) = makeStore()
        store.recordVisit(url: URL(string: "https://swift.org")!, title: "Swift Programming Language")
        store.recordVisit(url: URL(string: "https://example.com/cats")!, title: "Cat Pictures")

        #expect(store.search(query: "swift").count == 1)
        #expect(store.search(query: "cat").first?.url == "https://example.com/cats") // prefix match
        #expect(store.search(query: "zzz").isEmpty)
        #expect(store.search(query: "").isEmpty)
        #expect(store.search(query: "   ").isEmpty)
    }

    @Test("search sanitizes FTS syntax characters out of the query")
    func searchSanitizes() {
        let (store, _) = makeStore()
        store.recordVisit(url: URL(string: "https://example.com")!, title: "Hello World")
        // Quotes/parens are stripped so they can't break the FTS5 MATCH syntax;
        // the remaining words are searched as literal terms.
        #expect(store.search(query: "\"hello\" (world)").count == 1)
        // A word like AND survives sanitizing and is matched literally, so a
        // document without it yields no rows (rather than an FTS error).
        #expect(store.search(query: "hello AND world").isEmpty)
    }

    @Test("entries pages newest-first with limit and offset")
    func paging() {
        let (store, _) = makeStore()
        for i in 0..<5 {
            store.recordVisit(url: URL(string: "https://example.com/\(i)")!, title: "Page \(i)")
            Thread.sleep(forTimeInterval: 0.01) // distinct last_visit ordering
        }
        let all = store.entries()
        #expect(all.count == 5)
        #expect(all[0].url == "https://example.com/4") // newest first

        let page = store.entries(limit: 2, offset: 1)
        #expect(page.count == 2)
        #expect(page[0].url == "https://example.com/3")
    }

    @Test("entries filters through FTS when given a query")
    func entriesFiltered() {
        let (store, _) = makeStore()
        store.recordVisit(url: URL(string: "https://swift.org")!, title: "Swift")
        store.recordVisit(url: URL(string: "https://rust-lang.org")!, title: "Rust")

        let hits = store.entries(query: "swift")
        #expect(hits.count == 1)
        #expect(hits[0].title == "Swift")
    }

    @Test("delete removes the row, its FTS entry, and its visits")
    func delete() {
        let (store, db) = makeStore()
        store.recordVisit(url: URL(string: "https://example.com")!, title: "Example")
        store.recordVisit(url: URL(string: "https://keep.com")!, title: "Keep")

        store.delete(url: "https://example.com")

        #expect(store.entries().count == 1)
        #expect(store.search(query: "example").isEmpty) // FTS trigger cleaned up

        var visits = 0
        if let stmt = db.prepare("SELECT COUNT(*) FROM visits;") {
            if sqlite3_step(stmt) == SQLITE_ROW { visits = Int(sqlite3_column_int(stmt, 0)) }
            sqlite3_finalize(stmt)
        }
        #expect(visits == 1) // cascade removed the deleted item's visit
    }

    @Test("clearAll empties history and visits")
    func clearAll() {
        let (store, _) = makeStore()
        store.recordVisit(url: URL(string: "https://a.com")!, title: "A")
        store.recordVisit(url: URL(string: "https://b.com")!, title: "B")
        store.clearAll()
        #expect(store.entries().isEmpty)
        #expect(store.recentItems().isEmpty)
    }

    @Test("recentItems respects its limit")
    func recentItems() {
        let (store, _) = makeStore()
        for i in 0..<15 {
            store.recordVisit(url: URL(string: "https://example.com/\(i)")!, title: nil)
        }
        #expect(store.recentItems(limit: 10).count == 10)
    }
}
