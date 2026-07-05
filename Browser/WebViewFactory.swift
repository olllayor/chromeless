import Cocoa
import CoreLocation
import LocalAuthentication
import Security
import WebKit

// MARK: - WebViewFactory

enum WebViewFactory {
    static func makeConfiguration() -> WKWebViewConfiguration {
        let conf = WKWebViewConfiguration()
        conf.setURLSchemeHandler(InternalScheme.shared, forURLScheme: InternalScheme.scheme)
        conf.preferences.isElementFullscreenEnabled = true
        conf.mediaTypesRequiringUserActionForPlayback = []
        conf.allowsAirPlayForMediaPlayback = true
        conf.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        if !hasPasskeyEntitlement {
            let hideWebAuthn = WKUserScript(
                source: """
                (function () {
                  try {
                    delete window.PublicKeyCredential;
                    delete window.AuthenticatorResponse;
                    delete window.AuthenticatorAttestationResponse;
                    delete window.AuthenticatorAssertionResponse;
                  } catch (e) {}
                })();
                """,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false)
            conf.userContentController.addUserScript(hideWebAuthn)
        }
        ContentBlocker.shared.apply(to: conf.userContentController)
        Autofill.shared.install(on: conf)
        GeolocationBridge.shared.install(on: conf)
        SettingsBridge.shared.install(on: conf)
        return conf
    }
}
