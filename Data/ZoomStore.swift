import Cocoa
import CoreLocation
import LocalAuthentication
import Security
import WebKit

// MARK: - Per-site zoom persistence

enum ZoomStore {
    private static let key = "PerSiteZoom"

    static func zoom(for host: String) -> CGFloat {
        let dict = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        let fallback = UserDefaults.standard.object(forKey: "DefaultZoom") as? Double ?? 1.0
        return CGFloat(dict[host] ?? fallback)
    }

    static func set(_ zoom: CGFloat, for host: String) {
        var dict = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        if abs(zoom - 1.0) < 0.001 { dict.removeValue(forKey: host) }  // don't persist the default
        else { dict[host] = Double(zoom) }
        UserDefaults.standard.set(dict, forKey: key)
    }
}
