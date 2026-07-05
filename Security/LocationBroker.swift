import Cocoa
import CoreLocation
import LocalAuthentication
import Security
import WebKit

// MARK: - Location broker
//
// macOS WebKit has no per-site geolocation WKUIDelegate hook; it consults the
// host app's own CoreLocation authorization and then shows its own prompt. To
// make navigator.geolocation function at all the app must (a) ship a
// NSLocationWhenInUseUsageDescription and (b) hold a CLLocationManager whose
// authorization we can request and surface. Per-site control is therefore a
// system responsibility — the site-settings popover reflects the system state
// and links out to System Settings rather than pretending to gate it in-app.
final class LocationBroker: NSObject, CLLocationManagerDelegate {
    static let shared = LocationBroker()
    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
    }

    var status: CLAuthorizationStatus { manager.authorizationStatus }

    var statusText: String {
        switch status {
        case .authorizedAlways, .authorized: return "Allowed by macOS"
        case .denied: return "Blocked in macOS"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not yet requested"
        @unknown default: return "Unknown"
        }
    }

    /// Ask macOS for authorization if we've never asked; otherwise no-op.
    func ensureAuthorized() {
        if status == .notDetermined { manager.requestWhenInUseAuthorization() }
    }

    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {}
}
