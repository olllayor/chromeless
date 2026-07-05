import Cocoa
import CoreLocation
import LocalAuthentication
import Security
import WebKit

// MARK: - FaviconCache

final class FaviconCache {
    static let shared = FaviconCache()
    private let memCache = NSCache<NSString, NSImage>()
    private let diskDir: URL
    private let ioQueue = DispatchQueue(label: "chromeless.favicon.io", qos: .utility)

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        diskDir = appSupport.appendingPathComponent("Chromeless/Favicons", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskDir, withIntermediateDirectories: true)
        memCache.countLimit = 500
    }

    func favicon(for url: URL, completion: @escaping (NSImage?) -> Void) {
        guard let host = url.host else { completion(nil); return }
        let key = host as NSString
        // memCache is the fast path — keep it synchronous on the caller (main),
        // so a warm tab-bar rebuild never touches disk.
        if let cached = memCache.object(forKey: key) {
            completion(cached)
            return
        }
        let diskPath = diskDir.appendingPathComponent("\(host).png")
        // Disk read + network are pushed off the main thread; only the callback
        // hops back. Previously the Data(contentsOf:) blocked main on every miss.
        ioQueue.async { [weak self] in
            guard let self else { return }
            if let data = try? Data(contentsOf: diskPath),
               let img = NSImage(data: data) {
                self.memCache.setObject(img, forKey: key)
                DispatchQueue.main.async { completion(img) }
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
