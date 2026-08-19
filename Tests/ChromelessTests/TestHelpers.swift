import Foundation
@testable import ChromelessCore

// MARK: - Test isolation helpers
//
// The app's singletons read UserDefaults.standard and open the real database in
// Application Support. Tests must never touch either, so every suite that reads
// preferences points the injectable `defaults` seam at a throwaway suite domain,
// and every store test builds its DB from an in-memory or temp-file path.

/// A fresh, isolated UserDefaults domain. Register it with the seam under test,
/// and call `cleanup()` (or use `withDefaults`) to wipe it afterwards so state
/// never leaks between tests.
func makeSuiteDefaults(_ name: String = #function) -> UserDefaults {
    let suiteName = "chromeless.tests.\(name).\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    return defaults
}

/// Run `body` against an isolated UserDefaults suite, then remove the domain so
/// nothing persists. Returns whatever `body` returns.
func withDefaults<T>(_ body: (UserDefaults) throws -> T) rethrows -> T {
    let suiteName = "chromeless.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    return try body(defaults)
}

/// A throwaway on-disk SQLite database (temp file), removed after `body` runs.
/// Use this instead of `DB.inMemory()` when a test needs the DB to survive being
/// closed and reopened (e.g. persistence-across-restart semantics).
func withTempDB<T>(_ body: (DB) throws -> T) rethrows -> T {
    let dir = FileManager.default.temporaryDirectory
    let path = dir.appendingPathComponent("chromeless-test-\(UUID().uuidString).sqlite").path
    let db = DB(path: path)
    defer {
        try? FileManager.default.removeItem(atPath: path)
        // WAL/SHM sidecar files
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try? FileManager.default.removeItem(atPath: path + "-shm")
    }
    return try body(db)
}

/// A throwaway temp file URL (for BookmarkStore), removed after `body` runs.
func withTempFileURL<T>(_ body: (URL) throws -> T) rethrows -> T {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("chromeless-test-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    return try body(url)
}

// MARK: Global seam isolation
//
// `Bangs.defaults`, `SearchEngine.defaults` and `ZoomStore.defaults` are
// process-wide statics (the app runs with them pointed at `.standard`). Suites
// that swap them must not interleave, so the swap happens under one shared lock
// and every seam is restored afterwards.

private let seamLock = NSLock()

/// Point every UserDefaults-backed global seam at a fresh isolated suite
/// domain for the duration of `body`, then restore the previous domains.
/// Serialized across all tests via a shared lock.
func withIsolatedSeams<T>(_ body: () throws -> T) rethrows -> T {
    seamLock.lock()
    defer { seamLock.unlock() }
    let suiteName = "chromeless.tests.seams.\(UUID().uuidString)"
    let isolated = UserDefaults(suiteName: suiteName)!
    let previous = (bangs: Bangs.defaults, engine: SearchEngine.defaults, zoom: ZoomStore.defaults)
    Bangs.defaults = isolated
    SearchEngine.defaults = isolated
    ZoomStore.defaults = isolated
    defer {
        Bangs.defaults = previous.bangs
        SearchEngine.defaults = previous.engine
        ZoomStore.defaults = previous.zoom
        isolated.removePersistentDomain(forName: suiteName)
    }
    return try body()
}
