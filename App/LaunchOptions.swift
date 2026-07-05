import Cocoa
import CoreLocation
import LocalAuthentication
import Security
import WebKit

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
