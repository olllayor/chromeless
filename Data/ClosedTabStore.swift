import Cocoa
import CoreLocation
import LocalAuthentication
import Security
import WebKit

// MARK: - Reopen closed tab

/// App-wide stack of recently-closed tab URLs, restored newest-first via ⌘⇧T.
enum ClosedTabStore {
    private(set) static var stack: [URL] = []

    static func push(_ url: URL?) {
        guard let url, url.scheme == "http" || url.scheme == "https" else { return }
        stack.append(url)
        if stack.count > 50 { stack.removeFirst() }
    }

    static func pop() -> URL? { stack.popLast() }
}
