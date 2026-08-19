import Cocoa
import CoreLocation
import LocalAuthentication
import Security
import WebKit

// MARK: - Per-site zoom persistence

enum ZoomStore {
    private static let key = "PerSiteZoom"

    /// Where preferences live. Injectable so tests use a dedicated suite
    /// domain instead of the app's real defaults.
    static var defaults: UserDefaults = .standard

    static func zoom(for host: String) -> CGFloat {
        let dict = defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
        let fallback = defaults.object(forKey: "DefaultZoom") as? Double ?? 1.0
        return CGFloat(dict[host] ?? fallback)
    }

    static func set(_ zoom: CGFloat, for host: String) {
        var dict = defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
        if abs(zoom - 1.0) < 0.001 { dict.removeValue(forKey: host) }  // don't persist the default
        else { dict[host] = Double(zoom) }
        defaults.set(dict, forKey: key)
    }
}
