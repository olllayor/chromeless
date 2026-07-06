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

    /// The web view for a new tab. The prewarmed spare is only valid for the
    /// default identity (its data store is the shared jar); any other identity
    /// gets a freshly-built view wired to that identity's isolated store.
    /// Replenishes the default spare on the next runloop turn.
    static func dequeueWebView(for identity: Identity = IdentityStore.shared.defaultIdentity) -> BrowserWebView {
        if identity.isDefault {
            let wv = spare ?? BrowserWebView(frame: .zero, configuration: makeConfiguration(for: identity))
            spare = nil
            if prewarmEnabled { DispatchQueue.main.async { prewarm() } }
            return wv
        }
        return BrowserWebView(frame: .zero, configuration: makeConfiguration(for: identity))
    }

    static func makeConfiguration(for identity: Identity = IdentityStore.shared.defaultIdentity) -> WKWebViewConfiguration {
        let conf = WKWebViewConfiguration()
        // Per-identity cookie/storage isolation: the whole point of containers.
        // The default identity resolves to the shared `.default()` jar.
        conf.websiteDataStore = IdentityStore.shared.dataStore(for: identity)
        applyCommonConfig(to: conf)
        return conf
    }

    /// Install our scheme handler, prefs, user scripts, and JS bridges onto a
    /// configuration. Split out so `createWebViewWith` can decorate the
    /// WebKit-supplied popup configuration (which carries the opener's data store
    /// and window handle) instead of substituting a fresh one. Idempotent-safe on
    /// a fresh controller; guards the scheme handler (setting it twice throws).
    static func applyCommonConfig(to conf: WKWebViewConfiguration) {
        if conf.urlSchemeHandler(forURLScheme: InternalScheme.scheme) == nil {
            conf.setURLSchemeHandler(InternalScheme.shared, forURLScheme: InternalScheme.scheme)
        }
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
        // remove-before-add so decorating a reused/popup configuration can never
        // throw "already has a handler for <name>".
        let ucc = conf.userContentController
        ucc.addUserScript(StatusBubbleRelay.userScript)
        ucc.removeScriptMessageHandler(forName: "linkHover")
        ucc.add(StatusBubbleRelay.shared, name: "linkHover")
        // Safari-style pull-to-refresh: native gesture + injected indicator/gate.
        ucc.addUserScript(PullToRefreshRelay.userScript)
        ucc.removeScriptMessageHandler(forName: PullToRefreshRelay.gateName)
        ucc.add(PullToRefreshRelay.shared, name: PullToRefreshRelay.gateName)
    }
}
