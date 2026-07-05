import Cocoa
import CoreLocation
import LocalAuthentication
import Security
import WebKit

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
