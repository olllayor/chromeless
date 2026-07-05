import Cocoa
import CoreLocation
import LocalAuthentication
import Security
import WebKit

// MARK: - WebViewFactory

enum WebViewFactory {
    /// A pre-built web view handed to the next new tab: the configuration cost
    /// (user scripts, content-rule attach, scheme handler, view alloc) is paid
    /// off the critical path, while the user isn't waiting. Nothing is ever
    /// loaded into it, so tab history stays clean.
    private static var spare: BrowserWebView?

    static var prewarmEnabled: Bool {
        UserDefaults.standard.object(forKey: "PrewarmTabs") as? Bool ?? true
    }

    /// Build the spare if the feature is on and none is banked.
    static func prewarm() {
        guard prewarmEnabled, spare == nil else { return }
        spare = BrowserWebView(frame: .zero, configuration: makeConfiguration())
    }

    /// Drop the spare when configuration-time state changed under it
    /// (e.g. content blocking toggled) so the next tab isn't stale.
    static func discardSpare() {
        spare = nil
    }

    /// The web view for a new tab: the prewarmed spare when available, else a
    /// fresh build. Replenishes the spare on the next runloop turn.
    static func dequeueWebView() -> BrowserWebView {
        let wv = spare ?? BrowserWebView(frame: .zero, configuration: makeConfiguration())
        spare = nil
        if prewarmEnabled { DispatchQueue.main.async { prewarm() } }
        return wv
    }

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
        // Hover-link preview (status bubble): report hovered <a> hrefs.
        conf.userContentController.addUserScript(StatusBubbleRelay.userScript)
        conf.userContentController.add(StatusBubbleRelay.shared, name: "linkHover")
        return conf
    }
}
