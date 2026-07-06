import Cocoa
import CoreLocation
import LocalAuthentication
import Security
import WebKit
import SQLite3

// MARK: - History

final class HistoryStore {
    static let shared = HistoryStore()
    private let db = DB.shared

    func recordVisit(url: URL, title: String?) {
        guard let host = url.host, let absolute = url.absoluteString.nilIfEmpty else { return }
        let now = Date().timeIntervalSince1970
        let stmt = db.prepare(
            "INSERT INTO history_items (url, title, host, visit_count, last_visit) VALUES (?, ?, ?, 1, ?) " +
            // Keep the existing title if this revisit finished before its title was
            // set (empty) — otherwise a good title gets wiped to ''.
            "ON CONFLICT(url) DO UPDATE SET " +
            "title=CASE WHEN excluded.title<>'' THEN excluded.title ELSE history_items.title END, " +
            "visit_count=visit_count+1, last_visit=excluded.last_visit;"
        )
        if let stmt {
            sqlite3_bind_text(stmt, 1, absolute, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 2, title ?? "", -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 3, host, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_double(stmt, 4, now)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
        let idStmt = db.prepare("SELECT id FROM history_items WHERE url = ?;")
        if let idStmt {
            sqlite3_bind_text(idStmt, 1, absolute, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            if sqlite3_step(idStmt) == SQLITE_ROW {
                let itemId = sqlite3_column_int(idStmt, 0)
                sqlite3_finalize(idStmt)
                let visStmt = db.prepare("INSERT INTO visits (history_item_id, visit_time) VALUES (?, ?);")
                if let visStmt {
                    sqlite3_bind_int(visStmt, 1, itemId)
                    sqlite3_bind_double(visStmt, 2, now)
                    sqlite3_step(visStmt)
                    sqlite3_finalize(visStmt)
                }
            } else {
                sqlite3_finalize(idStmt)
            }
        }
    }

    func search(query: String) -> [(url: String, title: String)] {
        let allowed = CharacterSet.alphanumerics.union(.whitespaces).union(CharacterSet(charactersIn: ".-"))
        let sanitized = String(query.unicodeScalars.filter { allowed.contains($0) }).trimmingCharacters(in: .whitespaces)
        guard !sanitized.isEmpty else { return [] }
        let ftsQuery = sanitized.split(separator: " ").map { "\"\($0)\"*" }.joined(separator: " ")
        guard let fts = db.prepare(
            "SELECT hi.url, hi.title FROM history_fts fts " +
            "JOIN history_items hi ON hi.id = fts.rowid " +
            "WHERE history_fts MATCH ? ORDER BY hi.last_visit DESC LIMIT 8;"
        ) else { return [] }
        sqlite3_bind_text(fts, 1, ftsQuery, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        var results: [(url: String, title: String)] = []
        while sqlite3_step(fts) == SQLITE_ROW {
            let url = String(cString: sqlite3_column_text(fts, 0))
            let title = String(cString: sqlite3_column_text(fts, 1))
            results.append((url: url, title: title))
        }
        sqlite3_finalize(fts)
        return results
    }

    func recentItems(limit: Int = 10) -> [(url: String, title: String)] {
        guard let stmt = db.prepare(
            "SELECT url, title FROM history_items ORDER BY last_visit DESC LIMIT ?;"
        ) else { return [] }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        var results: [(url: String, title: String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let url = String(cString: sqlite3_column_text(stmt, 0))
            let title = String(cString: sqlite3_column_text(stmt, 1))
            results.append((url: url, title: title))
        }
        sqlite3_finalize(stmt)
        return results
    }

    struct Entry {
        let url: String
        let title: String
        let lastVisit: Double
    }

    /// Paged history for chromeless://history — newest first, optionally
    /// FTS-filtered by `query` (same sanitizing as omnibox search).
    func entries(query: String = "", limit: Int = 100, offset: Int = 0) -> [Entry] {
        let stmt: OpaquePointer?
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            stmt = db.prepare(
                "SELECT url, title, last_visit FROM history_items " +
                "ORDER BY last_visit DESC LIMIT ? OFFSET ?;")
            guard let stmt else { return [] }
            sqlite3_bind_int(stmt, 1, Int32(limit))
            sqlite3_bind_int(stmt, 2, Int32(offset))
        } else {
            let allowed = CharacterSet.alphanumerics.union(.whitespaces).union(CharacterSet(charactersIn: ".-"))
            let sanitized = String(trimmed.unicodeScalars.filter { allowed.contains($0) })
                .trimmingCharacters(in: .whitespaces)
            guard !sanitized.isEmpty else { return [] }
            let ftsQuery = sanitized.split(separator: " ").map { "\"\($0)\"*" }.joined(separator: " ")
            stmt = db.prepare(
                "SELECT hi.url, hi.title, hi.last_visit FROM history_fts fts " +
                "JOIN history_items hi ON hi.id = fts.rowid " +
                "WHERE history_fts MATCH ? ORDER BY hi.last_visit DESC LIMIT ? OFFSET ?;")
            guard let stmt else { return [] }
            sqlite3_bind_text(stmt, 1, ftsQuery, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_int(stmt, 2, Int32(limit))
            sqlite3_bind_int(stmt, 3, Int32(offset))
        }
        guard let stmt else { return [] }
        var results: [Entry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(Entry(url: String(cString: sqlite3_column_text(stmt, 0)),
                                 title: String(cString: sqlite3_column_text(stmt, 1)),
                                 lastVisit: sqlite3_column_double(stmt, 2)))
        }
        sqlite3_finalize(stmt)
        return results
    }

    /// Remove one URL from history (FTS + visits follow via trigger/cascade).
    func delete(url: String) {
        guard let stmt = db.prepare("DELETE FROM history_items WHERE url = ?;") else { return }
        sqlite3_bind_text(stmt, 1, url, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    func clearAll() {
        db.exec("DELETE FROM history_items;")
        db.exec("DELETE FROM visits;")
    }
}
