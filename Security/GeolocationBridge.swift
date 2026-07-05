import Cocoa
import CoreLocation
import LocalAuthentication
import Security
import WebKit

// MARK: - Geolocation bridge
//
// WebKit gives no delegate callback when a page calls navigator.geolocation, so
// we can't know to request CoreLocation authorization on demand. A tiny shim
// wraps the geolocation API and pings native the first time a site asks; native
// then requests system authorization if it hasn't already. Without this the
// system prompt would never appear and geolocation would silently fail.
final class GeolocationBridge: NSObject, WKScriptMessageHandler {
    static let shared = GeolocationBridge()
    static let messageName = "clGeoBridge"

    func install(on config: WKWebViewConfiguration) {
        let ucc = config.userContentController
        ucc.add(self, name: Self.messageName)
        ucc.addUserScript(WKUserScript(source: Self.script,
                                       injectionTime: .atDocumentStart,
                                       forMainFrameOnly: false))
    }

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        DispatchQueue.main.async { LocationBroker.shared.ensureAuthorized() }
    }

    private static let script = """
    (function () {
      try {
        var g = navigator.geolocation;
        if (!g) return;
        ['getCurrentPosition', 'watchPosition'].forEach(function (fn) {
          var orig = g[fn] && g[fn].bind(g);
          if (!orig) return;
          g[fn] = function () {
            try { window.webkit.messageHandlers.\(messageName).postMessage(1); } catch (e) {}
            return orig.apply(g, arguments);
          };
        });
      } catch (e) {}
    })();
    """
}
