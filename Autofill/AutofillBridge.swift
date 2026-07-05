import Cocoa
import CoreLocation
import LocalAuthentication
import Security
import WebKit

// MARK: - Autofill bridge (JS ⇄ native)

/// Injects a content script that detects login forms, offers to save on submit,
/// and fills fields on request. The native side trusts the frame's real
/// securityOrigin (never a JS-supplied URL) so a hostile sub-frame can't phish
/// another origin's credentials.
final class Autofill: NSObject, WKScriptMessageHandler {
    static let shared = Autofill()
    static let messageName = "clPasswordBridge"

    static var isEnabled: Bool { UserDefaults.standard.object(forKey: "AutofillEnabled") as? Bool ?? true }

    func install(on config: WKWebViewConfiguration) {
        let ucc = config.userContentController
        ucc.add(self, name: Self.messageName)
        ucc.addUserScript(WKUserScript(source: Self.script,
                                       injectionTime: .atDocumentEnd,
                                       forMainFrameOnly: false))
    }

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard Self.isEnabled,
              let body = message.body as? [String: Any],
              let action = body["action"] as? String,
              let webView = message.webView else { return }
        let origin = message.frameInfo.securityOrigin
        let scheme = origin.`protocol`
        guard !origin.host.isEmpty, scheme == "https" || scheme == "http" else { return }
        let host = origin.host
        guard let controller = webView.window?.windowController as? BrowserWindowController else { return }

        switch action {
        case "submit":
            guard let u = body["username"] as? String,
                  let p = body["password"] as? String, !p.isEmpty else { return }
            // Don't nag if this exact pair is already stored.
            if Vault.lookup(host: host).contains(where: { $0.username == u && $0.password == p }) { return }
            controller.promptSavePassword(host: host, username: u, password: p)
        case "requestFill":
            let matches = Vault.lookup(host: host)
            guard !matches.isEmpty else { return }
            controller.promptFill(host: host, matches: matches, webView: webView, frame: message.frameInfo)
        default:
            break
        }
    }

    /// Touch ID gate, then inject the credential into the requesting frame.
    static func authenticateAndFill(_ cred: Vault.Credential, into webView: WKWebView, frame: WKFrameInfo) {
        let ctx = LAContext()
        var err: NSError?
        if ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) {
            ctx.evaluatePolicy(.deviceOwnerAuthentication,
                               localizedReason: "fill your saved password") { ok, _ in
                guard ok else { return }
                DispatchQueue.main.async { fill(cred, into: webView, frame: frame) }
            }
        } else {
            fill(cred, into: webView, frame: frame)  // no biometrics/passcode available
        }
    }

    private static func fill(_ cred: Vault.Credential, into webView: WKWebView, frame: WKFrameInfo) {
        let arg: String = {
            let obj = ["u": cred.username, "p": cred.password]
            guard let data = try? JSONSerialization.data(withJSONObject: obj),
                  let s = String(data: data, encoding: .utf8) else { return "{}" }
            return s
        }()
        webView.evaluateJavaScript("window.__clFill && window.__clFill(\(arg));",
                                   in: frame, in: .page, completionHandler: nil)
    }

    // Runs in every frame (forMainFrameOnly:false); each frame reports its own origin.
    private static let script = """
    (function () {
      if (window.__clAutofill) return; window.__clAutofill = true;
      const bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(messageName);
      if (!bridge) return;

      function visible(el){ return !!(el && el.offsetParent !== null && !el.disabled); }

      function findCreds() {
        const pw = document.querySelector('input[type="password"]');
        if (!visible(pw)) return null;
        const fields = Array.prototype.slice.call(
          document.querySelectorAll('input[type="text"],input[type="email"],input[type="tel"],input:not([type])')
        ).filter(visible);
        // Prefer the visible text-ish field just before the password field.
        let user = fields.filter(function(e){
          return e.compareDocumentPosition(pw) & Node.DOCUMENT_POSITION_FOLLOWING;
        }).pop();
        if (!user) user = fields.find(function(e){
          return /user|email|login|account/i.test((e.name||'')+' '+(e.id||'')+' '+(e.getAttribute('autocomplete')||''));
        }) || fields[0] || null;
        return { user: user, pw: pw, form: pw.form };
      }

      function setVal(el, v){
        const proto = (el instanceof HTMLTextAreaElement) ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
        const setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
        setter.call(el, v);
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
      }

      window.__clFill = function(c){
        const f = findCreds(); if (!f) return;
        if (f.user && c.u) setVal(f.user, c.u);
        setVal(f.pw, c.p);
      };

      function offerSave(){
        const f = findCreds();
        if (f && f.pw.value) bridge.postMessage({
          action: 'submit',
          username: f.user ? f.user.value : '',
          password: f.pw.value
        });
      }

      document.addEventListener('submit', function(e){
        const f = findCreds();
        if (f && f.form === e.target) offerSave();
      }, true);

      // Many logins are XHR/JS with no real submit — also watch the click.
      document.addEventListener('click', function(e){
        const t = e.target.closest && e.target.closest('button,input[type=submit],[role=button]');
        if (t) setTimeout(offerSave, 0);
      }, true);

      // Ask native for creds whenever a login form appears. Many sites (cPanel,
      // SPAs) inject the password field AFTER load, so a one-shot check at
      // DOMContentLoaded misses it — observe the DOM and re-check, posting only
      // once per distinct password element.
      let lastPw = null, pending = false;
      function maybeRequest(){
        const f = findCreds();
        if (f && f.pw !== lastPw) { lastPw = f.pw; bridge.postMessage({ action: 'requestFill' }); }
      }
      function scheduleRequest(){
        if (pending) return;
        pending = true;
        setTimeout(function(){ pending = false; maybeRequest(); }, 60);
      }
      scheduleRequest();
      document.addEventListener('DOMContentLoaded', scheduleRequest);
      try {
        new MutationObserver(scheduleRequest).observe(
          document.documentElement, { childList: true, subtree: true });
      } catch (e) {}
      // Client-side route changes (SPA) can swap in a fresh login form.
      ['pushState', 'replaceState'].forEach(function(m){
        const orig = history[m];
        if (typeof orig === 'function') history[m] = function(){
          const r = orig.apply(this, arguments); scheduleRequest(); return r;
        };
      });
      window.addEventListener('popstate', scheduleRequest);
    })();
    """
}
