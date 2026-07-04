// chromeless — the browser that isn't there.
//
// A single-file macOS browser with zero chrome: no tabs, no toolbar, no
// address bar — just the page, in a bare rounded window. Built on WKWebView
// (the Safari engine). Made for clean screenshots and fullscreen video.
//
//   ⌘L  search / open url        ⇧⌘S  snapshot page → Desktop
//   ⌘R  reload                   ⌘P   pin window on top
//   ⌘[ ⌘]  back / forward        ⌃⌘F  fullscreen
//   ⌘= ⌘- ⌘0  zoom               ⌘drag  move the window
//
// CLI screenshot mode:
//   chromeless https://example.com --snap out.png --size 1440x900 --wait 2

import Cocoa
import Security
import WebKit

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

final class SuggestionRow: NSView {
    let index: Int
    private let clickAction: Selector
    private weak var clickTarget: AnyObject?

    init(index: Int, target: AnyObject?, action: Selector) {
        self.index = index
        self.clickAction = action
        self.clickTarget = target
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseUp(with event: NSEvent) {
        _ = clickTarget?.perform(clickAction, with: self)
    }
}

// MARK: - Passkey capability

// WKWebView performs WebAuthn (passkeys via iCloud Keychain / Touch ID) only for
// apps signed with Apple's restricted web-browser.public-key-credential
// entitlement, which needs an Apple-issued provisioning profile — macOS kills
// ad-hoc builds that claim it. So: if this build carries the entitlement,
// passkeys just work; if not, hide the WebAuthn API so sites feature-detect the
// absence and offer their fallback sign-in (password, phone prompt) instead of
// a passkey ceremony that is guaranteed to fail. See README for enabling it.
let hasPasskeyEntitlement: Bool = {
    guard let task = SecTaskCreateFromSelf(nil) else { return false }
    let value = SecTaskCopyValueForEntitlement(
        task, "com.apple.developer.web-browser.public-key-credential" as CFString, nil)
    return (value as? Bool) == true
}()

// MARK: - URL smarts

func smartURL(_ input: String) -> URL? {
    let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.isEmpty { return nil }
    if t.hasPrefix("/") || t.hasPrefix("~") {
        let path = (t as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
    }
    if t.contains("://") { return URL(string: t) }
    let lower = t.lowercased()
    for host in ["localhost", "127.0.0.1", "0.0.0.0", "[::1]"] where lower.hasPrefix(host) {
        return URL(string: "http://" + t)
    }
    if !t.contains(" "), t.contains(".") { return URL(string: "https://" + t) }
    let q = t.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? t
    return URL(string: "https://www.google.com/search?q=" + q)
}

// MARK: - WebViewFactory

enum WebViewFactory {
    static func makeConfiguration() -> WKWebViewConfiguration {
        let conf = WKWebViewConfiguration()
        conf.preferences.isElementFullscreenEnabled = true
        conf.mediaTypesRequiringUserActionForPlayback = []
        conf.allowsAirPlayForMediaPlayback = true
        conf.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        if !hasPasskeyEntitlement {
            let hideWebAuthn = WKUserScript(
                source: """
                (function () {
                  try {
                    delete window.PublicKeyCredential;
                    delete window.AuthenticatorResponse;
                    delete window.AuthenticatorAttestationResponse;
                    delete window.AuthenticatorAssertionResponse;
                  } catch (e) {}
                })();
                """,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false)
            conf.userContentController.addUserScript(hideWebAuthn)
        }
        return conf
    }
}

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

// MARK: - FaviconCache

final class FaviconCache {
    static let shared = FaviconCache()
    private let memCache = NSCache<NSString, NSImage>()
    private let diskDir: URL

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        diskDir = appSupport.appendingPathComponent("Chromeless/Favicons", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskDir, withIntermediateDirectories: true)
        memCache.countLimit = 500
    }

    func favicon(for url: URL, completion: @escaping (NSImage?) -> Void) {
        guard let host = url.host else { completion(nil); return }
        let key = host as NSString
        if let cached = memCache.object(forKey: key) {
            completion(cached)
            return
        }
        let diskPath = diskDir.appendingPathComponent("\(host).png")
        if let data = try? Data(contentsOf: diskPath),
           let img = NSImage(data: data) {
            memCache.setObject(img, forKey: key)
            completion(img)
            return
        }
        let iconURL = URL(string: "https://\(host)/favicon.ico") ?? url
        let task = URLSession.shared.dataTask(with: iconURL) { [weak self] data, _, _ in
            guard let data, let img = NSImage(data: data) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let resized = FaviconCache.resize(img, to: NSSize(width: 32, height: 32))
            self?.memCache.setObject(resized, forKey: key)
            try? resized.tiffRepresentation?.write(to: diskPath)
            DispatchQueue.main.async { completion(resized) }
        }
        task.resume()
    }

    private static func resize(_ image: NSImage, to size: NSSize) -> NSImage {
        let resized = NSImage(size: size)
        resized.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: size),
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .copy, fraction: 1.0)
        resized.unlockFocus()
        return resized
    }
}

// MARK: - Launch options

struct SnapJob { let path: String; let wait: TimeInterval }

struct LaunchOptions {
    var url: URL? = nil
    var snap: SnapJob? = nil
    var size: NSSize? = nil
}

func parseLaunchOptions() -> LaunchOptions {
    var opts = LaunchOptions()
    var snapPath: String? = nil
    var wait: TimeInterval = 1.0
    let args = Array(CommandLine.arguments.dropFirst())
    var i = 0
    while i < args.count {
        let a = args[i]
        switch a {
        case "--help", "-h":
            print("""
            chromeless — the browser that isn't there

            usage: chromeless [url] [options]
              --snap <path>     load the page, save a PNG of it, and quit
              --size <WxH>      window size in points (e.g. 1440x900)
              --wait <seconds>  extra settle time before --snap (default 1.0)

            examples:
              chromeless youtube.com
              chromeless localhost:3000 --snap shot.png --size 1280x800
            """)
            exit(0)
        case "--snap":
            i += 1
            if i < args.count { snapPath = args[i] }
        case "--size":
            i += 1
            if i < args.count {
                let parts = args[i].lowercased().split(separator: "x").compactMap { Double($0) }
                if parts.count == 2 { opts.size = NSSize(width: parts[0], height: parts[1]) }
            }
        case "--wait":
            i += 1
            if i < args.count { wait = Double(args[i]) ?? 1.0 }
        default:
            if a.hasPrefix("-") {
                fputs("chromeless: ignoring unknown option \(a)\n", stderr)
            } else if let u = smartURL(a) {
                opts.url = u
            }
        }
        i += 1
    }
    if let p = snapPath {
        let abs = p.hasPrefix("/") ? p : FileManager.default.currentDirectoryPath + "/" + p
        opts.snap = SnapJob(path: abs, wait: wait)
    }
    return opts
}

let launchOptions = parseLaunchOptions()

// MARK: - Start page

let startPageHTML = """
<!doctype html>
<html><head><meta charset="utf-8"><title>chromeless</title>
<style>
  html, body { height: 100%; margin: 0; }
  body { background: #0a0a0e; color: #e8e8ee; font: 15px/1.6 -apple-system, system-ui;
         display: flex; align-items: center; justify-content: center;
         -webkit-user-select: none; cursor: default; }
  main { text-align: center; max-width: 680px; padding: 48px; animation: in .6s ease-out; }
  @keyframes in { from { opacity: 0; transform: translateY(8px); } to { opacity: 1; } }
  h1 { font-size: 46px; font-weight: 650; letter-spacing: -.02em; margin: 0 0 6px; color: #fff; }
  p.tag { color: #85858f; margin: 0 0 46px; font-size: 16px; }
  .keys { display: grid; grid-template-columns: auto auto; gap: 11px 22px;
          justify-content: center; text-align: left; font-size: 13.5px; color: #b9b9c4; }
  .k { text-align: right; }
  kbd { font: 600 12px ui-monospace, "SF Mono", monospace; background: #1b1b22;
        border: 1px solid #2c2c36; border-bottom-width: 2px; border-radius: 6px;
        padding: 2.5px 8px; color: #e8e8ee; white-space: nowrap; }
  footer { margin-top: 48px; color: #55555e; font-size: 12px; }
</style></head>
<body><main>
  <h1>chromeless</h1>
  <p class="tag">the browser that isn&rsquo;t there</p>
  <div class="keys">
    <div class="k"><kbd>&#8984; L</kbd></div>       <div>search or enter a url</div>
    <div class="k"><kbd>&#8984; drag</kbd></div>    <div>move the window</div>
    <div class="k"><kbd>&#8963;&#8984; F</kbd></div><div>fullscreen</div>
    <div class="k"><kbd>&#8679;&#8984; S</kbd></div><div>snapshot the page &rarr; desktop</div>
    <div class="k"><kbd>&#8984; P</kbd></div>       <div>pin on top of every window</div>
    <div class="k"><kbd>&#8984; [</kbd> <kbd>&#8984; ]</kbd></div><div>back / forward</div>
    <div class="k"><kbd>esc</kbd></div>             <div>bail out &mdash; back to this page</div>
    <div class="k"><kbd>&#8984; =</kbd> <kbd>&#8984; &minus;</kbd> <kbd>&#8984; 0</kbd></div><div>zoom</div>
    <div class="k"><kbd>&#8679;&#8984; C</kbd></div><div>copy current url</div>
  </div>
  <footer>&#8984;N new window &nbsp;&middot;&nbsp; &#8984;R reload &nbsp;&middot;&nbsp; &#8984;W close</footer>
</main></body></html>
"""

// MARK: - Bookmarks

enum BookmarkType: String, Codable { case folder, bookmark }

struct BookmarkNode: Codable {
    var type: BookmarkType
    var title: String
    var url: String?
    var children: [BookmarkNode]?
}

final class BookmarkStore {
    static let shared = BookmarkStore()
    private var root: BookmarkNode
    private let fileURL: URL
    private var saveTimer: DispatchWorkItem?

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Chromeless", isDirectory: true)
        fileURL = dir.appendingPathComponent("bookmarks.json")
        if let data = try? Data(contentsOf: fileURL),
           let loaded = try? JSONDecoder().decode(BookmarkNode.self, from: data) {
            root = loaded
        } else {
            root = BookmarkNode(type: .folder, title: "Root", children: [
                BookmarkNode(type: .folder, title: "Favorites", children: [
                    BookmarkNode(type: .bookmark, title: "GitHub", url: "https://github.com"),
                    BookmarkNode(type: .bookmark, title: "Wikipedia", url: "https://wikipedia.org"),
                ])
            ])
            save()
        }
    }

    func addBookmark(url: String, title: String, folder: String = "Favorites") {
        let node = BookmarkNode(type: .bookmark, title: title, url: url)
        if modifyFolder(name: folder, in: &root, with: node) {
            // modified in place
        } else {
            root.children = (root.children ?? []) + [node]
        }
        scheduleSave()
    }

    private func modifyFolder(name: String, in node: inout BookmarkNode, with child: BookmarkNode) -> Bool {
        if node.type == .folder && node.title == name {
            node.children = (node.children ?? []) + [child]
            return true
        }
        for i in 0..<(node.children?.count ?? 0) {
            if modifyFolder(name: name, in: &node.children![i], with: child) { return true }
        }
        return false
    }

    func allBookmarks() -> [BookmarkNode] {
        return flatten(node: root)
    }

    private func flatten(node: BookmarkNode) -> [BookmarkNode] {
        if node.type == .bookmark { return [node] }
        return (node.children ?? []).flatMap { flatten(node: $0) }
    }

    private func findFolder(name: String, in node: BookmarkNode) -> BookmarkNode? {
        if node.type == .folder && node.title == name { return node }
        for child in (node.children ?? []) {
            if let found = findFolder(name: name, in: child) { return found }
        }
        return nil
    }

    private func scheduleSave() {
        saveTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(root) else { return }
        try? data.write(to: fileURL)
    }
}

// MARK: - History

final class HistoryStore {
    static let shared = HistoryStore()
    private let db = DB.shared

    func recordVisit(url: URL, title: String?) {
        guard let host = url.host, let absolute = url.absoluteString.nilIfEmpty else { return }
        let now = Date().timeIntervalSince1970
        let stmt = db.prepare(
            "INSERT INTO history_items (url, title, host, visit_count, last_visit) VALUES (?, ?, ?, 1, ?) " +
            "ON CONFLICT(url) DO UPDATE SET title=excluded.title, visit_count=visit_count+1, last_visit=excluded.last_visit;"
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

    func clearAll() {
        db.exec("DELETE FROM history_items;")
        db.exec("DELETE FROM visits;")
    }
}

// MARK: - Downloads

struct DownloadItem {
    let id = UUID()
    let filename: String
    let destinationURL: URL
    var receivedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var status: Status = .running
    enum Status { case running, completed, failed }
}

final class DownloadManager: NSObject, WKDownloadDelegate {
    static let shared = DownloadManager()
    var items: [DownloadItem] = []
    var onUpdate: (() -> Void)?
    private var activeDownloads: [ObjectIdentifier: DownloadItem] = [:]

    func start(_ download: WKDownload, filename: String) {
        download.delegate = self
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        var dest = downloads.appendingPathComponent(suggestedFilename)
        var counter = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            let name = (suggestedFilename as NSString).deletingPathExtension
            let ext = (suggestedFilename as NSString).pathExtension
            dest = downloads.appendingPathComponent("\(name) \(counter).\(ext)")
            counter += 1
        }
        let item = DownloadItem(filename: dest.lastPathComponent, destinationURL: dest)
        items.append(item)
        activeDownloads[ObjectIdentifier(download)] = item
        onUpdate?()
        completionHandler(dest)
    }

    func download(_ download: WKDownload, didReceive data: Data) {
        let key = ObjectIdentifier(download)
        guard var item = activeDownloads[key],
              let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        item.receivedBytes += Int64(data.count)
        items[idx] = item
        activeDownloads[key] = item
        onUpdate?()
    }

    func downloadDidFinish(_ download: WKDownload) {
        let key = ObjectIdentifier(download)
        guard var item = activeDownloads[key],
              let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        item.status = .completed
        items[idx] = item
        activeDownloads.removeValue(forKey: key)
        onUpdate?()
        DispatchQueue.main.async {
            if let wc = NSApp.keyWindow?.windowController as? BrowserWindowController {
                wc.showToast("Downloaded \(item.filename)")
            }
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let key = ObjectIdentifier(download)
        guard var item = activeDownloads[key],
              let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        item.status = .failed
        items[idx] = item
        activeDownloads.removeValue(forKey: key)
        onUpdate?()
    }
}

// MARK: - Tabs

final class Tab {
    let id = UUID()
    let webView: BrowserWebView
    var title: String = ""
    var url: URL?
    var isLoading: Bool = false
    var observations: [NSKeyValueObservation] = []

    init(webView: BrowserWebView) {
        self.webView = webView
        observations = [
            webView.observe(\.title) { [weak self] wv, _ in
                self?.title = wv.title ?? ""
            },
            webView.observe(\.url) { [weak self] wv, _ in
                self?.url = wv.url
            },
            webView.observe(\.isLoading) { [weak self] wv, _ in
                self?.isLoading = wv.isLoading
            },
        ]
    }

    deinit {
        observations.removeAll()
    }
}

final class TabBarItem: NSView {
    let index: Int
    let faviconView = NSImageView()
    let titleLabel = NSTextField(labelWithString: "")
    let closeButton = NSButton()
    var isSelected = false
    var isHovered = false
    private weak var target: AnyObject?
    private let clickAction: Selector
    private let closeAction: Selector

    init(index: Int, title: String, favicon: NSImage?, isSelected: Bool,
         target: AnyObject?, clickAction: Selector, closeAction: Selector) {
        self.index = index
        self.isSelected = isSelected
        self.target = target
        self.clickAction = clickAction
        self.closeAction = closeAction
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous

        faviconView.image = favicon
        faviconView.imageScaling = .scaleProportionallyDown
        faviconView.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(faviconView)

        titleLabel.stringValue = title.isEmpty ? "New Tab" : title
        titleLabel.font = .systemFont(ofSize: 12)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.truncatesLastVisibleLine = true
        titleLabel.maximumNumberOfLines = 1
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(titleLabel)

        closeButton.title = ""
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = target
        closeButton.action = closeAction
        closeButton.tag = index
        closeButton.setContentHuggingPriority(.required, for: .horizontal)
        closeButton.isHidden = true
        addSubview(closeButton)

        let click = NSClickGestureRecognizer(target: target, action: clickAction)
        addGestureRecognizer(click)

        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let h = bounds.height
        let pad: CGFloat = 8
        let favSize: CGFloat = 16
        let closeSize: CGFloat = 18
        let gap: CGFloat = 6

        var x: CGFloat = pad
        faviconView.frame = NSRect(x: x, y: (h - favSize) / 2, width: favSize, height: favSize)
        x += favSize + gap

        let closeW: CGFloat = closeButton.isHidden ? 0 : closeSize + 4
        let titleW = bounds.width - x - pad - closeW
        titleLabel.frame = NSRect(x: x, y: 0, width: max(0, titleW), height: h)

        if !closeButton.isHidden {
            closeButton.frame = NSRect(x: bounds.width - pad - closeSize, y: (h - closeSize) / 2,
                                        width: closeSize, height: closeSize)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateAppearance()
    }

    override var acceptsFirstResponder: Bool { true }

    func updateAppearance() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            if isSelected {
                layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
            } else if isHovered {
                layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
            } else {
                layer?.backgroundColor = NSColor.clear.cgColor
            }
            closeButton.animator().isHidden = !isHovered && !isSelected
        }
        titleLabel.textColor = isSelected ? .labelColor : .secondaryLabelColor
    }

    func update(title: String, favicon: NSImage?) {
        titleLabel.stringValue = title.isEmpty ? "New Tab" : title
        faviconView.image = favicon
    }
}

final class TabManager {
    var tabs: [Tab] = []
    private(set) var currentIndex: Int = 0
    var current: Tab? {
        guard currentIndex >= 0, currentIndex < tabs.count else { return nil }
        return tabs[currentIndex]
    }
    var onTabsChanged: (() -> Void)?

    func newTab(url: URL?, configuration: WKWebViewConfiguration) -> Tab {
        let wv = BrowserWebView(frame: .zero, configuration: configuration)
        let tab = Tab(webView: wv)
        tabs.append(tab)
        currentIndex = tabs.count - 1
        if let url { wv.load(URLRequest(url: url)) }
        onTabsChanged?()
        return tab
    }

    func select(_ tab: Tab) {
        guard let idx = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        currentIndex = idx
        onTabsChanged?()
    }

    func selectIndex(_ idx: Int) {
        guard idx >= 0, idx < tabs.count else { return }
        currentIndex = idx
        onTabsChanged?()
    }

    func close(_ tab: Tab) {
        guard let idx = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: idx)
        if currentIndex >= tabs.count { currentIndex = max(0, tabs.count - 1) }
        onTabsChanged?()
    }

    func closeCurrent() {
        guard !tabs.isEmpty else { return }
        close(tabs[currentIndex])
    }

    var count: Int { tabs.count }
    var isEmpty: Bool { tabs.isEmpty }
}

// MARK: - Views

final class BrowserWebView: WKWebView {
    // Bare Esc escapes back to the start page — unless fullscreen needs it,
    // or the ⌘L HUD is open (its field is first responder and handles Esc itself).
    var onEscape: (() -> Bool)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, // Esc
           event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
           window?.styleMask.contains(.fullScreen) != true,
           fullscreenState == .notInFullscreen,
           onEscape?() == true {
            return
        }
        super.keyDown(with: event)
    }

    // ⌘-drag anywhere moves the window; mouse buttons 4/5 go back/forward.
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            window?.performDrag(with: event)
            return
        }
        super.mouseDown(with: event)
    }
    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 3, canGoBack { goBack(); return }
        if event.buttonNumber == 4, canGoForward { goForward(); return }
        super.otherMouseUp(with: event)
    }
}

final class LayoutReportingView: NSView {
    var onLayout: (() -> Void)?
    override func layout() {
        super.layout()
        onLayout?()
    }
}

/// Holds HUD/find-bar overlays above WKWebView; clicks pass through empty areas to the page.
final class OverlayRootView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

// MARK: - Browser window

final class BrowserWindowController: NSWindowController, NSWindowDelegate,
    WKNavigationDelegate, WKUIDelegate, NSTextFieldDelegate, NSMenuItemValidation {

    var webView: BrowserWebView
    let tabManager = TabManager()
    private let overlayRoot = OverlayRootView()
    private let progressBar = NSView()
    private let hud = NSVisualEffectView()
    private let hudBacking = NSView()
    private let hudField = NSTextField()
    private let toastView = NSVisualEffectView()
    private let toastLabel = NSTextField(labelWithString: "")
    private var observations: [NSKeyValueObservation] = []
    private var mouseMonitor: Any?
    private var snapJob: SnapJob?
    private var toastHide: DispatchWorkItem?
    private var lastProgress: CGFloat = 0
    private var onStartPage = false
    var onClose: (() -> Void)?
    private let findBar = NSVisualEffectView()
    private let findField = NSTextField()
    private let findPrevButton = NSButton()
    private let findNextButton = NSButton()
    private let findCloseButton = NSButton()
    private let findStatusLabel = NSTextField(labelWithString: "")
    private var lastFindQuery: String?
    private var hudW: CGFloat = 620
    private let downloadsOverlay = NSVisualEffectView()
    private let downloadsStack = NSStackView()
    private let downloadsScrollView = NSScrollView()
    private let tabBar = NSVisualEffectView()
    private let tabStack = NSStackView()
    private var tabBarVisible = false
    private var tabBarTimer: DispatchWorkItem?
    private let suggestionsView = NSVisualEffectView()
    private let suggestionsBacking = NSView()
    private let suggestionsStack = NSStackView()
    private var suggestionItems: [(url: String, title: String)] = []
    private var selectedSuggestionIndex: Int = -1

    init(url: URL?, size: NSSize?, snap: SnapJob?, isPrimary: Bool) {
        let conf = WebViewFactory.makeConfiguration()
        webView = BrowserWebView(frame: .zero, configuration: conf)
        snapJob = snap

        let contentSize = size ?? NSSize(width: 1160, height: 760)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        super.init(window: window)

        window.title = "Chromeless"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 320, height: 220)
        window.backgroundColor = NSColor(calibratedWhite: 0.04, alpha: 1)
        window.appearance = NSAppearance(named: .darkAqua)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.acceptsMouseMovedEvents = true
        window.delegate = self
        setTrafficLights(visible: false)

        let container = LayoutReportingView(frame: NSRect(origin: .zero, size: contentSize))
        container.onLayout = { [weak self] in self?.layoutOverlays() }
        window.contentView = container

        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        webView.onEscape = { [weak self] in self?.escapeToStart() ?? false }
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.underPageBackgroundColor = NSColor(calibratedWhite: 0.04, alpha: 1)
        if #available(macOS 13.3, *) { webView.isInspectable = true }

        overlayRoot.wantsLayer = true
        overlayRoot.frame = container.bounds
        overlayRoot.autoresizingMask = [.width, .height]
        container.addSubview(overlayRoot)

        container.addSubview(webView, positioned: .below, relativeTo: overlayRoot)

        buildOverlays(in: overlayRoot)
        observeWebView()

        window.center()
        if isPrimary && snap == nil {
            window.setFrameUsingName("ChromelessMain")
            window.setFrameAutosaveName("ChromelessMain")
        } else if let key = NSApp.keyWindow {
            window.setFrameTopLeftPoint(NSPoint(x: key.frame.minX + 30, y: key.frame.maxY - 30))
        }
        if let size { window.setContentSize(size) }

        installMouseMonitor()

        let firstTab = Tab(webView: webView)
        tabManager.tabs.append(firstTab)
        tabManager.selectIndex(0)
        tabManager.onTabsChanged = { [weak self] in self?.refreshTabBar() }

        if let url { navigate(to: url) } else { loadStartPage() }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Chrome (what little there is)

    private func setTrafficLights(visible: Bool) {
        for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            window?.standardWindowButton(kind)?.isHidden = !visible
        }
    }

    private var isFullScreen: Bool { window?.styleMask.contains(.fullScreen) ?? false }

    private func installMouseMonitor() {
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            if event.type == .mouseMoved {
                guard let contentView = self.window?.contentView else { return event }
                let p = event.locationInWindow
                let nearCorner = p.y > contentView.bounds.height - 44 && p.x < 96
                self.setTrafficLights(visible: self.isFullScreen || nearCorner)
                // Tab bar: show when hovering top zone and >1 tab
                let nearTop = p.y > contentView.bounds.height - 24
                if nearTop && self.tabManager.count > 1 {
                    self.showTabBar()
                }
            } else if !self.hud.isHidden {
                let p = self.window!.contentView!.convert(event.locationInWindow, from: nil)
                if !self.hud.frame.contains(p) { self.hideHUD() }
            }
            return event
        }
    }

    // MARK: Find Bar

    @objc func showFindBar(_ sender: Any?) {
        if !hud.isHidden { hideHUD() }
        findField.stringValue = lastFindQuery ?? ""
        findBar.isHidden = false
        layoutOverlays()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            findBar.animator().alphaValue = 1
        }
        findField.selectText(nil)
    }

    @objc func hideFindBar(_ sender: Any?) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            self.findBar.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.findBar.isHidden = true
            self.window?.makeFirstResponder(self.webView)
        })
    }

    @objc func findNext(_ sender: Any?) {
        guard let query = findField.stringValue.nilIfEmpty else { return }
        lastFindQuery = query
        let config = WKFindConfiguration()
        config.backwards = false
        config.wraps = true
        webView.find(query, configuration: config) { [weak self] result in
            DispatchQueue.main.async {
                self?.findStatusLabel.stringValue = result.matchFound ? "✓" : "✗"
            }
        }
    }

    @objc func findPrev(_ sender: Any?) {
        guard let query = findField.stringValue.nilIfEmpty else { return }
        lastFindQuery = query
        let config = WKFindConfiguration()
        config.backwards = true
        config.wraps = true
        webView.find(query, configuration: config) { [weak self] result in
            DispatchQueue.main.async {
                self?.findStatusLabel.stringValue = result.matchFound ? "✓" : "✗"
            }
        }
    }

    @objc private func runFind() {
        guard let query = findField.stringValue.nilIfEmpty else {
            findStatusLabel.stringValue = ""
            return
        }
        lastFindQuery = query
        let config = WKFindConfiguration()
        config.backwards = false
        config.wraps = true
        webView.find(query, configuration: config) { [weak self] result in
            DispatchQueue.main.async {
                self?.findStatusLabel.stringValue = result.matchFound ? "✓" : "✗"
            }
        }
    }

    // MARK: Downloads Overlay

    @objc func toggleDownloads(_ sender: Any?) {
        downloadsOverlay.isHidden = !downloadsOverlay.isHidden
        if !downloadsOverlay.isHidden {
            refreshDownloads()
            downloadsOverlay.alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                downloadsOverlay.animator().alphaValue = 1
            }
        }
    }

    @objc func addBookmark(_ sender: Any?) {
        guard let url = webView.url, url.absoluteString != "about:blank" else {
            showToast("Can't bookmark this page")
            return
        }
        let alert = NSAlert()
        alert.messageText = "Add Bookmark"
        alert.informativeText = url.absoluteString
        let titleField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        titleField.stringValue = webView.title ?? ""
        alert.accessoryView = titleField
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            BookmarkStore.shared.addBookmark(url: url.absoluteString, title: titleField.stringValue)
            showToast("Bookmark added")
        }
    }

    func newTab(url: URL? = nil) {
        let conf = WebViewFactory.makeConfiguration()
        let wv = BrowserWebView(frame: .zero, configuration: conf)
        let tab = Tab(webView: wv)
        tabManager.tabs.append(tab)
        switchToTab(tab)
        if let url {
            wv.load(URLRequest(url: url))
        } else {
            loadStartPage()
        }
    }

    func closeCurrentTab() {
        if tabManager.count <= 1 {
            let oldTab = tabManager.tabs.first
            oldTab?.webView.removeFromSuperview()
            let newTab = Tab(webView: BrowserWebView(frame: .zero, configuration: WebViewFactory.makeConfiguration()))
            tabManager.tabs = [newTab]
            tabManager.selectIndex(0)
            switchToTab(newTab)
            loadStartPage()
            return
        }
        let prevIndex = max(0, tabManager.currentIndex - 1)
        tabManager.closeCurrent()
        switchToTab(tabManager.tabs[prevIndex])
    }

    private func switchToTab(_ tab: Tab) {
        guard let container = window?.contentView else { return }
        if let current = tabManager.current {
            current.webView.removeFromSuperview()
        }
        tabManager.select(tab)
        container.addSubview(tab.webView, positioned: .below, relativeTo: overlayRoot)
        tab.webView.frame = container.bounds
        tab.webView.autoresizingMask = [.width, .height]
        webView = tab.webView
        window?.title = tab.title.isEmpty ? "Chromeless" : tab.title
        observations.removeAll()
        observations = [
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in
                self?.progressChanged(wv.estimatedProgress)
            },
            webView.observe(\.title) { [weak self] wv, _ in
                let t = wv.title ?? ""
                self?.window?.title = t.isEmpty ? "Chromeless" : t
                self?.refreshTabBar()
            },
            webView.observe(\.url) { wv, _ in
                if let u = wv.url, u.scheme == "https" || u.scheme == "http" {
                    UserDefaults.standard.set(u.absoluteString, forKey: "LastURL")
                }
            },
        ]
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.onEscape = { [weak self] in self?.escapeToStart() ?? false }
    }

    // MARK: Tab Bar

    @objc func toggleTabBar(_ sender: Any?) {
        if tabBar.isHidden { showTabBar() } else { hideTabBar() }
    }

    private func showTabBar() {
        guard tabManager.count > 1 else { return }
        let shouldAnimate = tabBar.isHidden
        tabBar.isHidden = false
        if shouldAnimate {
            tabBar.alphaValue = 0
            refreshTabBar()
            layoutOverlays()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                tabBar.animator().alphaValue = 1
            }
        }
        resetTabBarTimer()
    }

    private func resetTabBarTimer() {
        tabBarTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if !NSMouseInRect(NSEvent.mouseLocation, self.tabBar.frame,
                              self.window?.isFlipped ?? false) {
                self.hideTabBar()
            }
        }
        tabBarTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    private func hideTabBar() {
        guard !tabBar.isHidden else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            self.tabBar.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.tabBar.isHidden = true
        })
    }

    private func refreshTabBar() {
        tabStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, tab) in tabManager.tabs.enumerated() {
            let item = TabBarItem(
                index: i,
                title: tab.title,
                favicon: nil,
                isSelected: i == tabManager.currentIndex,
                target: self,
                clickAction: #selector(tabItemClicked(_:)),
                closeAction: #selector(tabItemCloseClicked(_:))
            )
            item.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                item.heightAnchor.constraint(equalToConstant: 30),
                item.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
                item.widthAnchor.constraint(lessThanOrEqualToConstant: 220),
            ])
            tabStack.addArrangedSubview(item)

            if let url = tab.url {
                FaviconCache.shared.favicon(for: url) { [weak item] img in
                    DispatchQueue.main.async { item?.update(title: tab.title, favicon: img) }
                }
            }
        }
        let addBtn = NSButton(title: "", target: self, action: #selector(newTabFromBar(_:)))
        addBtn.bezelStyle = .inline
        addBtn.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New tab")
        addBtn.contentTintColor = .secondaryLabelColor
        addBtn.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            addBtn.widthAnchor.constraint(equalToConstant: 28),
            addBtn.heightAnchor.constraint(equalToConstant: 28),
        ])
        tabStack.addArrangedSubview(addBtn)
    }

    @objc private func tabItemClicked(_ sender: NSClickGestureRecognizer) {
        guard let item = sender.view as? TabBarItem else { return }
        guard item.index < tabManager.count else { return }
        switchToTab(tabManager.tabs[item.index])
        refreshTabBar()
    }

    @objc private func tabItemCloseClicked(_ sender: NSButton) {
        let idx = sender.tag
        guard idx < tabManager.count else { return }
        if tabManager.count == 1 {
            window?.close()
        } else {
            let prevIndex = max(0, idx - 1)
            tabManager.closeCurrent()
            switchToTab(tabManager.tabs[prevIndex])
            refreshTabBar()
        }
    }

    @objc private func newTabFromBar(_ sender: Any?) {
        newTab()
        refreshTabBar()
    }

    private func refreshDownloads() {
        downloadsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for item in DownloadManager.shared.items.reversed() {
            let row = NSView()
            let label = NSTextField(labelWithString: item.filename)
            label.font = .systemFont(ofSize: 12)
            label.lineBreakMode = .byTruncatingMiddle
            let statusLabel = NSTextField(labelWithString: item.status == .completed ? "✓" : "\(item.receivedBytes)")
            statusLabel.font = .systemFont(ofSize: 11)
            statusLabel.textColor = .secondaryLabelColor
            row.addSubview(label)
            row.addSubview(statusLabel)
            label.frame = NSRect(x: 0, y: 0, width: 280, height: 28)
            statusLabel.frame = NSRect(x: 290, y: 0, width: 70, height: 28)
            row.frame = NSRect(x: 0, y: 0, width: 360, height: 36)
            downloadsStack.addArrangedSubview(row)
        }
        layoutOverlays()
    }

    private func buildOverlays(in container: NSView) {
        progressBar.wantsLayer = true
        progressBar.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        progressBar.alphaValue = 0
        container.addSubview(progressBar)

        hud.material = .hudWindow
        hud.blendingMode = .withinWindow
        hud.state = .active
        hud.wantsLayer = true
        hud.layer?.cornerRadius = 26
        hud.layer?.cornerCurve = .continuous
        hud.layer?.masksToBounds = true
        hud.layer?.borderWidth = 1
        hud.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        hud.isHidden = true
        hud.alphaValue = 0
        hudBacking.wantsLayer = true
        hudBacking.autoresizingMask = [.width, .height]
        hudBacking.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 0.96).cgColor
        hudBacking.layer?.cornerRadius = 26
        hudBacking.layer?.cornerCurve = .continuous
        hud.addSubview(hudBacking)
        hudField.isBezeled = false
        hudField.isBordered = false
        hudField.drawsBackground = false
        hudField.focusRingType = .none
        hudField.font = .systemFont(ofSize: 16)
        hudField.textColor = NSColor(calibratedWhite: 0.95, alpha: 1)
        hudField.placeholderAttributedString = NSAttributedString(
            string: "Search or enter address",
            attributes: [.foregroundColor: NSColor(calibratedWhite: 0.55, alpha: 1)])
        hudField.usesSingleLineMode = true
        hudField.cell?.isScrollable = true
        hudField.cell?.wraps = false
        hudField.delegate = self
        hud.addSubview(hudField)
        container.addSubview(hud)

        toastView.material = .hudWindow
        toastView.blendingMode = .withinWindow
        toastView.state = .active
        toastView.wantsLayer = true
        toastView.layer?.cornerRadius = 17
        toastView.layer?.cornerCurve = .continuous
        toastView.layer?.masksToBounds = true
        toastView.isHidden = true
        toastView.alphaValue = 0
        toastLabel.font = .systemFont(ofSize: 13, weight: .medium)
        toastLabel.textColor = .labelColor
        toastView.addSubview(toastLabel)
        container.addSubview(toastView)

        findBar.material = .hudWindow
        findBar.blendingMode = .withinWindow
        findBar.state = .active
        findBar.wantsLayer = true
        findBar.layer?.cornerRadius = 18
        findBar.layer?.cornerCurve = .continuous
        findBar.layer?.masksToBounds = true
        findBar.layer?.borderWidth = 1
        findBar.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        findBar.isHidden = true
        findBar.alphaValue = 0

        findPrevButton.title = "▲"
        findPrevButton.bezelStyle = .inline
        findPrevButton.target = self
        findPrevButton.action = #selector(findPrev(_:))
        findBar.addSubview(findPrevButton)

        findField.isBezeled = false
        findField.isBordered = false
        findField.drawsBackground = false
        findField.focusRingType = .none
        findField.font = .systemFont(ofSize: 14)
        findField.textColor = .labelColor
        findField.placeholderString = "Find"
        findField.usesSingleLineMode = true
        findField.cell?.isScrollable = true
        findField.cell?.wraps = false
        findField.delegate = self
        findBar.addSubview(findField)

        findStatusLabel.font = .systemFont(ofSize: 12)
        findStatusLabel.textColor = .secondaryLabelColor
        findBar.addSubview(findStatusLabel)

        findNextButton.title = "▼"
        findNextButton.bezelStyle = .inline
        findNextButton.target = self
        findNextButton.action = #selector(findNext(_:))
        findBar.addSubview(findNextButton)

        findCloseButton.title = "×"
        findCloseButton.bezelStyle = .inline
        findCloseButton.target = self
        findCloseButton.action = #selector(hideFindBar(_:))
        findBar.addSubview(findCloseButton)

        container.addSubview(findBar)

        downloadsOverlay.material = .hudWindow
        downloadsOverlay.blendingMode = .withinWindow
        downloadsOverlay.state = .active
        downloadsOverlay.wantsLayer = true
        downloadsOverlay.layer?.cornerRadius = 18
        downloadsOverlay.layer?.cornerCurve = .continuous
        downloadsOverlay.layer?.masksToBounds = true
        downloadsOverlay.layer?.borderWidth = 1
        downloadsOverlay.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        downloadsOverlay.isHidden = true
        downloadsOverlay.alphaValue = 0

        downloadsStack.orientation = .vertical
        downloadsStack.spacing = 4
        downloadsStack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)

        downloadsScrollView.documentView = downloadsStack
        downloadsScrollView.hasVerticalScroller = true
        downloadsScrollView.drawsBackground = false
        downloadsOverlay.addSubview(downloadsScrollView)

        container.addSubview(downloadsOverlay)

        DownloadManager.shared.onUpdate = { [weak self] in
            DispatchQueue.main.async { self?.refreshDownloads() }
        }

        suggestionsView.material = .hudWindow
        suggestionsView.blendingMode = .withinWindow
        suggestionsView.state = .active
        suggestionsView.wantsLayer = true
        suggestionsView.layer?.cornerRadius = 12
        suggestionsView.layer?.cornerCurve = .continuous
        suggestionsView.layer?.masksToBounds = true
        suggestionsView.layer?.borderWidth = 1
        suggestionsView.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        suggestionsView.isHidden = true

        suggestionsBacking.wantsLayer = true
        suggestionsBacking.autoresizingMask = [.width, .height]
        suggestionsBacking.layer?.backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 0.96).cgColor
        suggestionsBacking.layer?.cornerRadius = 12
        suggestionsBacking.layer?.cornerCurve = .continuous
        suggestionsView.addSubview(suggestionsBacking)

        suggestionsStack.orientation = .vertical
        suggestionsStack.spacing = 0
        suggestionsStack.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        suggestionsStack.translatesAutoresizingMaskIntoConstraints = false

        suggestionsView.addSubview(suggestionsStack)
        container.addSubview(suggestionsView)

        tabBar.material = .hudWindow
        tabBar.blendingMode = .withinWindow
        tabBar.state = .active
        tabBar.wantsLayer = true
        tabBar.layer?.cornerRadius = 18
        tabBar.layer?.cornerCurve = .continuous
        tabBar.layer?.masksToBounds = true
        tabBar.layer?.borderWidth = 1
        tabBar.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        tabBar.isHidden = true
        tabBar.alphaValue = 0

        tabStack.orientation = .horizontal
        tabStack.spacing = 2
        tabStack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        tabBar.addSubview(tabStack)

        container.addSubview(tabBar)
    }

    private func layoutOverlays() {
        guard let contentView = window?.contentView else { return }
        overlayRoot.frame = contentView.bounds
        let b = overlayRoot.bounds
        hudW = min(620, max(280, b.width - 48))
        let hudH: CGFloat = 52
        hud.frame = NSRect(x: (b.width - hudW) / 2, y: b.height - hudH - 84, width: hudW, height: hudH)
        hudBacking.frame = hud.bounds
        hudField.frame = NSRect(x: 20, y: (hudH - 22) / 2, width: hudW - 40, height: 22)

        toastLabel.sizeToFit()
        let ts = toastLabel.frame.size
        let tw = ts.width + 32
        let th: CGFloat = 34
        toastView.frame = NSRect(x: (b.width - tw) / 2, y: 28, width: tw, height: th)
        toastLabel.frame = NSRect(x: 16, y: (th - ts.height) / 2, width: ts.width, height: ts.height)

        progressBar.frame = NSRect(x: 0, y: b.height - 2, width: b.width * lastProgress, height: 2)

        let fbW: CGFloat = 360
        let fbH: CGFloat = 40
        let fbX = b.width - fbW - 20
        let fbY: CGFloat = 20
        findBar.frame = NSRect(x: fbX, y: fbY, width: fbW, height: fbH)

        let btnSize: CGFloat = 24
        let padding: CGFloat = 8
        var fbXPos: CGFloat = padding
        findPrevButton.frame = NSRect(x: fbXPos, y: (fbH - btnSize) / 2, width: btnSize, height: btnSize)
        fbXPos += btnSize + 4

        let fieldW = fbW - (padding * 2) - (btnSize * 4) - 12
        findField.frame = NSRect(x: fbXPos, y: (fbH - 20) / 2, width: fieldW, height: 20)
        fbXPos += fieldW + 4

        findStatusLabel.frame = NSRect(x: fbXPos, y: (fbH - 16) / 2, width: 40, height: 16)
        fbXPos += 44

        findNextButton.frame = NSRect(x: fbXPos, y: (fbH - btnSize) / 2, width: btnSize, height: btnSize)
        fbXPos += btnSize + 4

        findCloseButton.frame = NSRect(x: fbXPos, y: (fbH - btnSize) / 2, width: btnSize, height: btnSize)

        if !downloadsOverlay.isHidden {
            let dovW: CGFloat = 380
            let dovH: CGFloat = min(440, CGFloat(max(1, DownloadManager.shared.items.count)) * 44 + 16)
            downloadsOverlay.frame = NSRect(x: b.width - dovW - 20, y: b.height - dovH - 44,
                                              width: dovW, height: dovH)
            downloadsScrollView.frame = downloadsOverlay.bounds
        }

        if !suggestionsView.isHidden {
            let svW = hudW
            let svH = CGFloat(min(suggestionItems.count, 8)) * 32 + 8
            suggestionsView.frame = NSRect(x: hud.frame.minX, y: hud.frame.minY - svH - 4,
                                            width: svW, height: svH)
            suggestionsBacking.frame = suggestionsView.bounds
            suggestionsStack.frame = suggestionsView.bounds.insetBy(dx: 4, dy: 4)
        }

        if !tabBar.isHidden && tabManager.count > 1 {
            let tbW = min(600, max(200, CGFloat(tabManager.count) * 160 + 40))
            let tbH: CGFloat = 36
            tabBar.frame = NSRect(x: (b.width - tbW) / 2, y: b.height - tbH - 8,
                                   width: tbW, height: tbH)
            tabStack.frame = tabBar.bounds
        }
    }

    private func observeWebView() {
        observations = [
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in
                self?.progressChanged(wv.estimatedProgress)
            },
            webView.observe(\.title) { [weak self] wv, _ in
                let t = wv.title ?? ""
                self?.window?.title = t.isEmpty ? "Chromeless" : t
                self?.refreshTabBar()
            },
            webView.observe(\.url) { wv, _ in
                if let u = wv.url, u.scheme == "https" || u.scheme == "http" {
                    UserDefaults.standard.set(u.absoluteString, forKey: "LastURL")
                }
            },
        ]
    }

    private func progressChanged(_ progress: Double) {
        lastProgress = CGFloat(progress)
        if let width = window?.contentView?.bounds.width {
            progressBar.frame.size.width = width * lastProgress
        }
        if progress >= 1.0 {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.35
                progressBar.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                self?.lastProgress = 0
                self?.layoutOverlays()
            })
        } else {
            progressBar.alphaValue = 1
        }
    }

    // MARK: Navigation

    func navigate(to url: URL) {
        onStartPage = false
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    func loadStartPage() {
        onStartPage = true
        webView.loadHTMLString(startPageHTML, baseURL: nil)
    }

    private func escapeToStart() -> Bool {
        if onStartPage { return false }
        loadStartPage()
        return true
    }

    // MARK: HUD (the ⌘L address bar)

    func showHUD() {
        if let u = webView.url, !onStartPage, u.absoluteString != "about:blank" {
            hudField.stringValue = u.absoluteString
        } else {
            hudField.stringValue = ""
        }
        hud.isHidden = false
        layoutOverlays()
        hud.alphaValue = 0.9
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            hud.animator().alphaValue = 1
        }
        window?.makeFirstResponder(hudField)
        hudField.selectText(nil)
    }

    func hideHUD() {
        suggestionsView.isHidden = true
        selectedSuggestionIndex = -1
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            self.hud.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.hud.isHidden = true
            self.window?.makeFirstResponder(self.webView)
        })
    }

    private func commitHUD() {
        let text = hudField.stringValue
        hideHUD()
        if let url = smartURL(text) { navigate(to: url) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if control == findField {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                hideFindBar(nil)
                return true
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                findNext(nil)
                return true
            }
            return false
        }
        if control == hudField {
            if commandSelector == #selector(NSResponder.moveUp(_:)) {
                if selectedSuggestionIndex > 0 { selectedSuggestionIndex -= 1; highlightSuggestion() }
                return true
            }
            if commandSelector == #selector(NSResponder.moveDown(_:)) {
                if selectedSuggestionIndex < suggestionItems.count - 1 { selectedSuggestionIndex += 1; highlightSuggestion() }
                return true
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if selectedSuggestionIndex >= 0 && selectedSuggestionIndex < suggestionItems.count {
                    let item = suggestionItems[selectedSuggestionIndex]
                    hideHUD()
                    if let url = URL(string: item.url) { navigate(to: url) }
                } else {
                    commitHUD()
                }
                return true
            }
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { hideHUD(); suggestionsView.isHidden = true; return true }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { commitHUD(); return true }
        return false
    }

    func controlTextDidChange(_ obj: Notification) {
        if obj.object as? NSTextField == findField {
            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(runFind), object: nil)
            perform(#selector(runFind), with: nil, afterDelay: 0.15)
        } else if obj.object as? NSTextField == hudField {
            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(updateSuggestions), object: nil)
            perform(#selector(updateSuggestions), with: nil, afterDelay: 0.15)
        }
    }

    @objc private func updateSuggestions() {
        let text = hudField.stringValue.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2 else {
            suggestionsView.isHidden = true
            return
        }
        suggestionItems = HistoryStore.shared.search(query: text)
        guard !suggestionItems.isEmpty else {
            suggestionsView.isHidden = true
            return
        }
        suggestionsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        selectedSuggestionIndex = -1
        for (i, item) in suggestionItems.prefix(8).enumerated() {
            let row = SuggestionRow(index: i, target: self, action: #selector(suggestionRowClicked(_:)))
            let titleLabel = NSTextField(labelWithString: item.title.isEmpty ? item.url : item.title)
            titleLabel.font = .systemFont(ofSize: 13)
            titleLabel.lineBreakMode = .byTruncatingMiddle
            let urlLabel = NSTextField(labelWithString: item.url)
            urlLabel.font = .systemFont(ofSize: 11)
            urlLabel.textColor = .tertiaryLabelColor
            row.addSubview(titleLabel)
            row.addSubview(urlLabel)
            titleLabel.frame = NSRect(x: 12, y: 14, width: hudW - 24, height: 16)
            urlLabel.frame = NSRect(x: 12, y: 0, width: hudW - 24, height: 14)
            row.frame = NSRect(x: 0, y: 0, width: hudW, height: 32)
            suggestionsStack.addArrangedSubview(row)
        }
        suggestionsView.isHidden = false
        layoutOverlays()
    }

    @objc private func suggestionRowClicked(_ sender: SuggestionRow) {
        guard sender.index < suggestionItems.count else { return }
        let item = suggestionItems[sender.index]
        hideHUD()
        if let url = URL(string: item.url) { navigate(to: url) }
    }

    private func highlightSuggestion() {
        for (i, subview) in suggestionsStack.arrangedSubviews.enumerated() {
            subview.layer?.backgroundColor = (i == selectedSuggestionIndex)
                ? NSColor.controlAccentColor.withAlphaComponent(0.2).cgColor
                : NSColor.clear.cgColor
        }
    }

    // MARK: Toast

    func showToast(_ text: String) {
        toastLabel.stringValue = text
        layoutOverlays()
        toastHide?.cancel()
        toastView.isHidden = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            toastView.animator().alphaValue = 1
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.4
                self.toastView.animator().alphaValue = 0
            }, completionHandler: { self.toastView.isHidden = true })
        }
        toastHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.7, execute: work)
    }

    // MARK: Snapshots

    private func writePNG(from image: NSImage, to path: String) -> (Int, Int)? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
        else { return nil }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            return (cg.width, cg.height)
        } catch {
            return nil
        }
    }

    private func runSnapJob(_ job: SnapJob) {
        DispatchQueue.main.asyncAfter(deadline: .now() + job.wait) { [weak self] in
            guard let self else { exit(3) }
            self.webView.takeSnapshot(with: nil) { image, error in
                guard let image, let dims = self.writePNG(from: image, to: job.path) else {
                    fputs("chromeless: snapshot failed: \(error?.localizedDescription ?? "could not write PNG")\n", stderr)
                    exit(3)
                }
                print("saved \(job.path) (\(dims.0)x\(dims.1) px)")
                exit(0)
            }
        }
    }

    // MARK: Menu actions

    @objc func openLocation(_ sender: Any?) { showHUD() }

    @objc func reloadPage(_ sender: Any?) {
        if onStartPage { loadStartPage() } else { webView.reload() }
    }

    @objc func hardReloadPage(_ sender: Any?) {
        if onStartPage { loadStartPage() } else { webView.reloadFromOrigin() }
    }

    @objc func goBackAction(_ sender: Any?) { webView.goBack() }
    @objc func goForwardAction(_ sender: Any?) { webView.goForward() }

    @objc func zoomInPage(_ sender: Any?) { webView.pageZoom = min(webView.pageZoom * 1.1, 5.0) }
    @objc func zoomOutPage(_ sender: Any?) { webView.pageZoom = max(webView.pageZoom / 1.1, 0.25) }
    @objc func resetZoom(_ sender: Any?) { webView.pageZoom = 1.0 }

    @objc func saveSnapshot(_ sender: Any?) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let name = "chromeless \(formatter.string(from: Date())).png"
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let path = desktop.appendingPathComponent(name).path
        webView.takeSnapshot(with: nil) { [weak self] image, _ in
            guard let self else { return }
            if let image, self.writePNG(from: image, to: path) != nil {
                self.showToast("Saved “\(name)” to Desktop")
            } else {
                self.showToast("Snapshot failed")
            }
        }
    }

    @objc func copyPageURL(_ sender: Any?) {
        guard let u = webView.url, u.absoluteString != "about:blank" else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(u.absoluteString, forType: .string)
        showToast("URL copied")
    }

    @objc func togglePin(_ sender: Any?) {
        guard let window else { return }
        let pinned = window.level == .floating
        window.level = pinned ? .normal : .floating
        showToast(pinned ? "Unpinned" : "Pinned on top")
    }

    @objc func showHelpPage(_ sender: Any?) { loadStartPage() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(goBackAction(_:)): return webView.canGoBack
        case #selector(goForwardAction(_:)): return webView.canGoForward
        case #selector(copyPageURL(_:)):
            return webView.url != nil && webView.url?.absoluteString != "about:blank"
        case #selector(togglePin(_:)):
            menuItem.state = window?.level == .floating ? .on : .off
            return true
        default: return true
        }
    }

    // MARK: NSWindowDelegate

    func windowDidEnterFullScreen(_ notification: Notification) { setTrafficLights(visible: true) }
    func windowDidExitFullScreen(_ notification: Notification) { setTrafficLights(visible: false) }

    func windowWillClose(_ notification: Notification) {
        if let monitor = mouseMonitor { NSEvent.removeMonitor(monitor) }
        mouseMonitor = nil
        observations.removeAll()
        onClose?()
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        let u = webView.url?.absoluteString
        if u != nil && u != "about:blank" { onStartPage = false }
        if !findBar.isHidden { hideFindBar(nil) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let url = webView.url, !onStartPage,
           let scheme = url.scheme, scheme == "http" || scheme == "https" {
            HistoryStore.shared.recordVisit(url: url, title: webView.title ?? "")
        }

        if let job = snapJob {
            snapJob = nil
            runSnapJob(job)
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleLoadError(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleLoadError(error)
    }

    private func handleLoadError(_ error: Error) {
        let e = error as NSError
        // Ignore cancelled loads and "frame load interrupted" (downloads, redirects).
        if e.code == NSURLErrorCancelled || e.code == 102 { return }
        if launchOptions.snap != nil {
            fputs("chromeless: load failed: \(e.localizedDescription)\n", stderr)
            exit(1)
        }
        showToast("Couldn’t load — \(e.localizedDescription)")
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Hand non-web schemes (mailto:, facetime:, app links…) to the system.
        if let url = navigationAction.request.url, let scheme = url.scheme?.lowercased(),
           !["http", "https", "file", "about", "data", "blob", "javascript"].contains(scheme) {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if !navigationResponse.canShowMIMEType {
            decisionHandler(.download)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse,
                 didBecome download: WKDownload) {
        DownloadManager.shared.start(download, filename: navigationResponse.response.suggestedFilename ?? "download")
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction,
                 didBecome download: WKDownload) {
        DownloadManager.shared.start(download, filename: "download")
    }

    // MARK: WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            newTab(url: url)
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil)
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var controllers: [BrowserWindowController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMenu()

        let urlsToRestore: [URL] = {
            if let u = launchOptions.url { return [u] }
            if launchOptions.snap != nil { return [] }
            if let saved = UserDefaults.standard.array(forKey: "OpenTabs") as? [String],
               !saved.isEmpty {
                return saved.compactMap { URL(string: $0) }
            }
            if let s = UserDefaults.standard.string(forKey: "LastURL"),
               let url = URL(string: s) {
                return [url]
            }
            return []
        }()

        if urlsToRestore.isEmpty {
            openWindow(url: nil, size: launchOptions.size, snap: launchOptions.snap, isPrimary: true)
        } else {
            openWindow(url: urlsToRestore.first, size: launchOptions.size, snap: launchOptions.snap, isPrimary: true)
            if let primaryController = controllers.first {
                for url in urlsToRestore.dropFirst() {
                    primaryController.newTab(url: url)
                }
            }
        }
        NSApp.activate(ignoringOtherApps: true)

        if launchOptions.snap != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                fputs("chromeless: --snap timed out\n", stderr)
                exit(2)
            }
        }
    }

    func openWindow(url: URL?, size: NSSize? = nil, snap: SnapJob? = nil, isPrimary: Bool = false) {
        let controller = BrowserWindowController(url: url, size: size, snap: snap, isPrimary: isPrimary)
        controller.onClose = { [weak self, weak controller] in
            self?.controllers.removeAll { $0 === controller }
        }
        controllers.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    @objc func newWindow(_ sender: Any?) { openWindow(url: nil) }

    @objc func openLocation(_ sender: Any?) {
        (NSApp.keyWindow?.windowController as? BrowserWindowController)?.showHUD()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        var tabURLs: [String] = []
        for wc in controllers {
            for tab in wc.tabManager.tabs {
                if let url = tab.url?.absoluteString {
                    tabURLs.append(url)
                }
            }
        }
        UserDefaults.standard.set(tabURLs, forKey: "OpenTabs")
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { openWindow(url: url) }
    }

    // MARK: Menu

    private func buildMenu() {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Chromeless",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Chromeless", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                                         action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Chromeless", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(withTitle: "Chromeless", action: nil, keyEquivalent: "").submenu = appMenu

        let fileMenu = NSMenu(title: "File")
        let newWin = fileMenu.addItem(withTitle: "New Window", action: #selector(newWindow(_:)), keyEquivalent: "n")
        newWin.target = self
        let openLocation = fileMenu.addItem(withTitle: "Open Location…",
                                            action: #selector(AppDelegate.openLocation(_:)), keyEquivalent: "l")
        openLocation.target = self
        fileMenu.addItem(.separator())
        let snap = fileMenu.addItem(withTitle: "Save Snapshot to Desktop",
                                    action: #selector(BrowserWindowController.saveSnapshot(_:)), keyEquivalent: "s")
        snap.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "New Tab",
                         action: #selector(AppDelegate.newTab(_:)), keyEquivalent: "t")
        fileMenu.addItem(withTitle: "Close Tab",
                         action: #selector(AppDelegate.closeTab(_:)), keyEquivalent: "w")
        fileMenu.addItem(withTitle: "Close Window",
                         action: #selector(NSWindow.performClose(_:)), keyEquivalent: "W")
        main.addItem(withTitle: "File", action: nil, keyEquivalent: "").submenu = fileMenu

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: NSSelectorFromString("redo:"), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        let copyURL = editMenu.addItem(withTitle: "Copy Current URL",
                                       action: #selector(BrowserWindowController.copyPageURL(_:)), keyEquivalent: "c")
        copyURL.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Find…",
                         action: #selector(BrowserWindowController.showFindBar(_:)), keyEquivalent: "f")
        editMenu.addItem(withTitle: "Find Next",
                         action: #selector(BrowserWindowController.findNext(_:)), keyEquivalent: "g")
        editMenu.addItem(withTitle: "Find Previous",
                         action: #selector(BrowserWindowController.findPrev(_:)), keyEquivalent: "G")
        main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = editMenu

        let bookmarksMenu = NSMenu(title: "Bookmarks")
        bookmarksMenu.delegate = self
        bookmarksMenu.addItem(withTitle: "Add Bookmark…",
                              action: #selector(BrowserWindowController.addBookmark(_:)), keyEquivalent: "d")
        bookmarksMenu.addItem(.separator())
        main.addItem(withTitle: "Bookmarks", action: nil, keyEquivalent: "").submenu = bookmarksMenu

        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Reload Page",
                         action: #selector(BrowserWindowController.reloadPage(_:)), keyEquivalent: "r")
        let hardReload = viewMenu.addItem(withTitle: "Reload Ignoring Cache",
                                          action: #selector(BrowserWindowController.hardReloadPage(_:)), keyEquivalent: "r")
        hardReload.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Zoom In",
                         action: #selector(BrowserWindowController.zoomInPage(_:)), keyEquivalent: "=")
        viewMenu.addItem(withTitle: "Zoom Out",
                         action: #selector(BrowserWindowController.zoomOutPage(_:)), keyEquivalent: "-")
        viewMenu.addItem(withTitle: "Actual Size",
                         action: #selector(BrowserWindowController.resetZoom(_:)), keyEquivalent: "0")
        viewMenu.addItem(.separator())
        let fullScreen = viewMenu.addItem(withTitle: "Enter Full Screen",
                                          action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        main.addItem(withTitle: "View", action: nil, keyEquivalent: "").submenu = viewMenu

        let historyMenu = NSMenu(title: "History")
        historyMenu.delegate = self
        historyMenu.addItem(withTitle: "Back",
                            action: #selector(BrowserWindowController.goBackAction(_:)), keyEquivalent: "[")
        historyMenu.addItem(withTitle: "Forward",
                            action: #selector(BrowserWindowController.goForwardAction(_:)), keyEquivalent: "]")
        main.addItem(withTitle: "History", action: nil, keyEquivalent: "").submenu = historyMenu

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Pin on Top",
                           action: #selector(BrowserWindowController.togglePin(_:)), keyEquivalent: "p")
        windowMenu.addItem(withTitle: "Downloads",
                           action: #selector(BrowserWindowController.toggleDownloads(_:)), keyEquivalent: "j")
            .keyEquivalentModifierMask = [.command, .shift]
        windowMenu.addItem(withTitle: "Tab Bar",
                           action: #selector(BrowserWindowController.toggleTabBar(_:)), keyEquivalent: "t")
            .keyEquivalentModifierMask = [.option, .command]
        main.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(withTitle: "Chromeless Help",
                         action: #selector(BrowserWindowController.showHelpPage(_:)), keyEquivalent: "?")
        main.addItem(withTitle: "Help", action: nil, keyEquivalent: "").submenu = helpMenu
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = main
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu.title == "History" {
            menu.removeAllItems()
            menu.addItem(withTitle: "Back", action: #selector(BrowserWindowController.goBackAction(_:)), keyEquivalent: "[")
            menu.addItem(withTitle: "Forward", action: #selector(BrowserWindowController.goForwardAction(_:)), keyEquivalent: "]")
            menu.addItem(.separator())
            let recent = HistoryStore.shared.recentItems(limit: 10)
            for item in recent {
                let mi = menu.addItem(withTitle: item.title.isEmpty ? item.url : item.title,
                                      action: #selector(openHistoryItem(_:)), keyEquivalent: "")
                mi.representedObject = item.url
                mi.target = self
            }
            if !recent.isEmpty { menu.addItem(.separator()) }
            menu.addItem(withTitle: "Clear History…",
                         action: #selector(clearHistory(_:)), keyEquivalent: "")
        }
        if menu.title == "Bookmarks" {
            let existing = menu.items.filter { $0.tag == 100 }
            existing.forEach { menu.removeItem($0) }
            let bookmarks = BookmarkStore.shared.allBookmarks()
            if !bookmarks.isEmpty {
                let sep = NSMenuItem.separator()
                sep.tag = 100
                menu.addItem(sep)
            }
            for bm in bookmarks.prefix(20) {
                let mi = menu.addItem(withTitle: bm.title, action: #selector(openBookmark(_:)), keyEquivalent: "")
                mi.representedObject = bm.url
                mi.target = self
                mi.tag = 100
            }
        }
    }

    @objc func openBookmark(_ sender: NSMenuItem) {
        guard let urlString = sender.representedObject as? String,
              let url = URL(string: urlString) else { return }
        if let wc = NSApp.keyWindow?.windowController as? BrowserWindowController {
            wc.navigate(to: url)
        }
    }

    @objc func newTab(_ sender: Any?) {
        if let wc = NSApp.keyWindow?.windowController as? BrowserWindowController {
            wc.newTab()
        } else {
            openWindow(url: nil)
        }
    }

    @objc func closeTab(_ sender: Any?) {
        if let wc = NSApp.keyWindow?.windowController as? BrowserWindowController {
            wc.closeCurrentTab()
        }
    }

    @objc func openHistoryItem(_ sender: NSMenuItem) {
        guard let urlString = sender.representedObject as? String,
              let url = URL(string: urlString) else { return }
        if let wc = NSApp.keyWindow?.windowController as? BrowserWindowController {
            wc.navigate(to: url)
        }
    }

    @objc func clearHistory(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Clear all browsing history?"
        alert.informativeText = "This cannot be undone."
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            HistoryStore.shared.clearAll()
        }
    }
}

// MARK: - Boot

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
