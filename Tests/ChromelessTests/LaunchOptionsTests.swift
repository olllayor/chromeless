import Foundation
import Testing
@testable import ChromelessCore

@Suite("LaunchOptions — CLI argument parsing")
struct LaunchOptionsTests {

    @Test("No arguments yields empty options")
    func empty() {
        let opts = parseLaunchOptions(args: [])
        #expect(opts.url == nil)
        #expect(opts.snap == nil)
        #expect(opts.size == nil)
    }

    @Test("A bare positional argument is resolved through smartURL")
    func positionalURL() {
        let opts = parseLaunchOptions(args: ["example.com"])
        #expect(opts.url?.absoluteString == "https://example.com")
    }

    @Test("--snap captures the path and default wait")
    func snap() {
        let opts = parseLaunchOptions(args: ["--snap", "/tmp/shot.png"])
        #expect(opts.snap?.path == "/tmp/shot.png")
        #expect(opts.snap?.wait == 1.0)
    }

    @Test("--snap with a relative path is anchored at the current directory")
    func snapRelative() {
        let opts = parseLaunchOptions(args: ["--snap", "shot.png"])
        let cwd = FileManager.default.currentDirectoryPath
        #expect(opts.snap?.path == cwd + "/shot.png")
    }

    @Test("--wait overrides the settle time")
    func wait() {
        let opts = parseLaunchOptions(args: ["--snap", "/tmp/s.png", "--wait", "2.5"])
        #expect(opts.snap?.wait == 2.5)
    }

    @Test("--wait falls back to 1.0 on garbage")
    func waitGarbage() {
        let opts = parseLaunchOptions(args: ["--snap", "/tmp/s.png", "--wait", "soon"])
        #expect(opts.snap?.wait == 1.0)
    }

    @Test("--size parses WxH case-insensitively")
    func size() {
        let opts = parseLaunchOptions(args: ["--size", "1440x900"])
        #expect(opts.size?.width == 1440)
        #expect(opts.size?.height == 900)

        let upper = parseLaunchOptions(args: ["--size", "1280X800"])
        #expect(upper.size?.width == 1280)
    }

    @Test("--size ignores malformed values")
    func sizeMalformed() {
        #expect(parseLaunchOptions(args: ["--size", "big"]).size == nil)
        #expect(parseLaunchOptions(args: ["--size", "100x"]).size == nil)
        #expect(parseLaunchOptions(args: ["--size"]).size == nil) // missing value
    }

    @Test("Unknown flags are ignored; options combine")
    func combined() {
        let opts = parseLaunchOptions(args: ["--bogus", "localhost:3000", "--size", "800x600"])
        #expect(opts.url?.absoluteString == "http://localhost:3000")
        #expect(opts.size?.width == 800)
    }
}
