import Foundation
import Testing
@testable import ChromelessCore

@Suite("BookmarkStore — tree operations and JSON persistence")
struct BookmarkStoreTests {

    @Test("A fresh store seeds the default tree")
    func defaultTree() {
        withTempFileURL { url in
            let store = BookmarkStore(fileURL: url)
            let all = store.allBookmarks()
            #expect(all.count == 2) // GitHub + Wikipedia under Favorites
            #expect(all.map(\.title).sorted() == ["GitHub", "Wikipedia"])
        }
    }

    @Test("Init writes the default tree to disk synchronously")
    func defaultTreePersisted() {
        withTempFileURL { url in
            _ = BookmarkStore(fileURL: url)
            #expect(FileManager.default.fileExists(atPath: url.path))

            // A second store over the same file loads what the first wrote.
            let reloaded = BookmarkStore(fileURL: url)
            #expect(reloaded.allBookmarks().count == 2)
        }
    }

    @Test("addBookmark targets a named folder")
    func addToFolder() {
        withTempFileURL { url in
            let store = BookmarkStore(fileURL: url)
            store.addBookmark(url: "https://example.com", title: "Example", folder: "Favorites")
            let all = store.allBookmarks()
            #expect(all.count == 3)
            #expect(all.contains { $0.title == "Example" && $0.url == "https://example.com" })
        }
    }

    @Test("addBookmark falls back to the root when the folder is missing")
    func addFallbackToRoot() {
        withTempFileURL { url in
            let store = BookmarkStore(fileURL: url)
            store.addBookmark(url: "https://orphan.example", title: "Orphan", folder: "NoSuchFolder")
            #expect(store.allBookmarks().contains { $0.title == "Orphan" })
        }
    }

    @Test("BookmarkNode round-trips through JSON")
    func jsonRoundTrip() throws {
        let node = BookmarkNode(type: .folder, title: "Root", children: [
            BookmarkNode(type: .folder, title: "Inner", children: [
                BookmarkNode(type: .bookmark, title: "Deep", url: "https://deep.example"),
            ]),
            BookmarkNode(type: .bookmark, title: "Top", url: nil),
        ])
        let data = try JSONEncoder().encode(node)
        let decoded = try JSONDecoder().decode(BookmarkNode.self, from: data)
        #expect(decoded == node)
    }

    @Test("A corrupt bookmarks file falls back to the default tree")
    func corruptFile() throws {
        try withTempFileURL { url in
            try Data("not json at all".utf8).write(to: url)
            let store = BookmarkStore(fileURL: url)
            #expect(store.allBookmarks().count == 2) // default seeds
        }
    }
}
