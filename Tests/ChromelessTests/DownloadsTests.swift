import Foundation
import Testing
@testable import ChromelessCore

@Suite("Downloads — filename sanitization and progress math")
struct DownloadsTests {

    // MARK: sanitizedFilename

    @Test("Plain names pass through unchanged")
    func plain() {
        #expect(DownloadManager.sanitizedFilename("report.pdf") == "report.pdf")
        #expect(DownloadManager.sanitizedFilename("file.tar.gz") == "file.tar.gz")
        #expect(DownloadManager.sanitizedFilename("my report (1).pdf") == "my report (1).pdf")
    }

    @Test("Path components and traversal are dropped")
    func path() {
        #expect(DownloadManager.sanitizedFilename("/tmp/dir/file.txt") == "file.txt")
        #expect(DownloadManager.sanitizedFilename("../../etc/passwd") == "passwd")
        #expect(DownloadManager.sanitizedFilename("a/b/c.png") == "c.png")
    }

    @Test("Colons become dashes")
    func colons() {
        // WebKit sometimes hands back macOS-style "volume:dir:file" names;
        // colons are legal in HFS+ but ambiguous, so they get neutralized.
        #expect(DownloadManager.sanitizedFilename("C:Documents:report.pdf") == "C-Documents-report.pdf")
    }

    @Test("Leading dots are stripped and whitespace trimmed")
    func dots() {
        #expect(DownloadManager.sanitizedFilename(".hidden") == "hidden")
        #expect(DownloadManager.sanitizedFilename("..") == "download")
        #expect(DownloadManager.sanitizedFilename("   spaced.txt   ") == "spaced.txt")
    }

    @Test("Empty input never yields an empty name")
    func empty() {
        #expect(DownloadManager.sanitizedFilename("") == "download")
        #expect(DownloadManager.sanitizedFilename("....") == "download")
    }

    // MARK: DownloadItem.fraction

    @Test("fraction is nil when the total size is unknown")
    func indeterminate() {
        let item = DownloadItem(filename: "f", destinationURL: URL(fileURLWithPath: "/tmp/f"))
        #expect(item.fraction == nil)
    }

    @Test("fraction tracks progress and caps at 1.0")
    func fraction() {
        var item = DownloadItem(filename: "f", destinationURL: URL(fileURLWithPath: "/tmp/f"))
        item.totalBytes = 200
        item.receivedBytes = 50
        #expect(item.fraction == 0.25)
        item.receivedBytes = 300 // servers lie; never show > 100%
        #expect(item.fraction == 1.0)
    }

    // MARK: activeProgress

    @Test("activeProgress is nil with nothing running")
    func noActive() {
        let mgr = DownloadManager()
        #expect(mgr.activeProgress == nil)
        var done = DownloadItem(filename: "d", destinationURL: URL(fileURLWithPath: "/tmp/d"))
        done.status = .completed
        done.totalBytes = 100
        done.receivedBytes = 100
        mgr.items = [done]
        #expect(mgr.activeProgress == nil)
    }

    @Test("activeProgress combines running downloads, ignoring indeterminate ones")
    func activeProgress() {
        let mgr = DownloadManager()
        var a = DownloadItem(filename: "a", destinationURL: URL(fileURLWithPath: "/tmp/a"))
        a.totalBytes = 100; a.receivedBytes = 25
        var b = DownloadItem(filename: "b", destinationURL: URL(fileURLWithPath: "/tmp/b"))
        b.totalBytes = 100; b.receivedBytes = 75
        let c = DownloadItem(filename: "c", destinationURL: URL(fileURLWithPath: "/tmp/c"))
        mgr.items = [a, b, c] // c has no known total, so it must not skew the math
        #expect(mgr.activeProgress == 0.5)
    }
}