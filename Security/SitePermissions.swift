import Cocoa
import CoreLocation
import LocalAuthentication
import Security
import WebKit

// MARK: - Site permissions
//
// Per-origin decisions for the capture permissions WebKit routes through
// WKUIDelegate (camera, microphone). Persisted in UserDefaults keyed by
// "scheme://host" so a choice survives relaunch. Geolocation is deliberately
// absent here: macOS WebKit resolves it against the *app's* CoreLocation
// authorization (see LocationBroker), not a per-site WKUIDelegate callback,
// so there is no in-app grant/deny to store.
enum SitePermission: String, CaseIterable {
    case camera, microphone

    var label: String {
        switch self {
        case .camera: return "Camera"
        case .microphone: return "Microphone"
        }
    }
    var symbol: String {
        switch self {
        case .camera: return "video.fill"
        case .microphone: return "mic.fill"
        }
    }
}

enum PermissionDecision: String {
    case ask, allow, deny
}

final class SitePermissionStore {
    static let shared = SitePermissionStore()
    private let defaultsKey = "SitePermissions"

    // origin -> [permission.rawValue: decision.rawValue]
    private var table: [String: [String: String]]

    private init() {
        table = UserDefaults.standard.dictionary(forKey: defaultsKey)
            as? [String: [String: String]] ?? [:]
    }

    /// Canonical origin key. Nil for schemes that can't own a permission.
    static func origin(for url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty else { return nil }
        return "\(scheme)://\(host)"
    }

    static func origin(for o: WKSecurityOrigin) -> String? {
        let scheme = o.`protocol`.lowercased()
        guard scheme == "https" || scheme == "http", !o.host.isEmpty else { return nil }
        return "\(scheme)://\(o.host)"
    }

    func decision(_ origin: String, _ permission: SitePermission) -> PermissionDecision {
        guard let raw = table[origin]?[permission.rawValue],
              let d = PermissionDecision(rawValue: raw) else { return .ask }
        return d
    }

    func set(_ origin: String, _ permission: SitePermission, _ decision: PermissionDecision) {
        var row = table[origin] ?? [:]
        if decision == .ask { row[permission.rawValue] = nil }
        else { row[permission.rawValue] = decision.rawValue }
        if row.isEmpty { table[origin] = nil } else { table[origin] = row }
        persist()
    }

    /// Origins with at least one non-default decision, for the settings table.
    func origins() -> [String] { table.keys.sorted() }

    /// Forget every decision for one origin.
    func reset(_ origin: String) { table[origin] = nil; persist() }

    /// Forget all sites.
    func clearAll() { table = [:]; persist() }

    private func persist() { UserDefaults.standard.set(table, forKey: defaultsKey) }
}
