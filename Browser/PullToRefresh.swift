import Cocoa
import WebKit

// MARK: - Pull-to-refresh (Safari-style)
//
// Overscrolling downward at the very top of a page — a two-finger swipe down on
// the trackpad past a limit — reloads it, matching Safari on macOS 27.
//
// The GESTURE is detected natively in BrowserWebView.scrollWheel using NSEvent
// phases, so trackpad *momentum* (which has no phase) can never trigger a reload
// — a JS wheel listener cannot tell a finger-drag from momentum, which would
// cause spurious reloads when you fling up to the top. An injected script only
// (a) reports whether a pull is currently allowed (page at top, not inside a
// scrollable element that can still scroll up), and (b) draws the indicator when
// the native side calls window.__clPTR.
final class PullToRefreshRelay: NSObject, WKScriptMessageHandler {
    static let shared = PullToRefreshRelay()
    // The page posts true/false as the pull-eligibility gate changes.
    static let gateName = "ptrGate"

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.gateName,
              let wv = message.webView as? BrowserWebView else { return }
        wv.pullAllowed = (message.body as? Bool) ?? false
    }

    static let userScript = WKUserScript(source: js,
                                         injectionTime: .atDocumentStart,
                                         forMainFrameOnly: true)

    private static let js = """
    (function () {
      // --- eligibility gate: is a pull-to-refresh allowed right now? ---
      function atTop() {
        var se = document.scrollingElement || document.documentElement;
        return (window.scrollY || (se && se.scrollTop) || 0) <= 0;
      }
      // True if the wheel is inside a scroll container that can still scroll up —
      // then the user is scrolling that, not overscrolling the page.
      function innerCanScrollUp(target) {
        var el = target;
        while (el && el.nodeType === 1 && el !== document.body && el !== document.documentElement) {
          if (el.scrollHeight > el.clientHeight) {
            var oy = getComputedStyle(el).overflowY;
            if ((oy === 'auto' || oy === 'scroll') && el.scrollTop > 0) return true;
          }
          el = el.parentElement;
        }
        return false;
      }
      var lastGate = null;
      function gate(v) {
        if (v === lastGate) return;
        lastGate = v;
        try { window.webkit.messageHandlers.ptrGate.postMessage(v); } catch (e) {}
      }
      window.addEventListener('wheel', function (e) {
        gate(e.deltaY < 0 && atTop() && !innerCanScrollUp(e.target));
      }, { passive: true });
      window.addEventListener('scroll', function () { if (!atTop()) gate(false); }, { passive: true });

      // --- indicator: bare macOS radial spinner, driven by the native side ---
      var ind = null, spin = null;
      function build() {
        if (ind) return;
        ind = document.createElement('div');
        ind.style.cssText =
          'position:fixed;top:0;left:50%;z-index:2147483647;pointer-events:none;' +
          'opacity:0;transform:translate(-50%,-30px) scale(.6);transition:opacity .15s ease;';
        spin = document.createElement('div');
        spin.style.cssText = 'position:relative;width:24px;height:24px;';
        for (var i = 0; i < 12; i++) {
          var bar = document.createElement('div');
          bar.style.cssText =
            'position:absolute;left:11px;top:1px;width:2px;height:6px;border-radius:1px;' +
            'background:#8a8a8a;transform-origin:1px 11px;' +
            'transform:rotate(' + (i * 30) + 'deg);opacity:' + ((i + 1) / 12).toFixed(2) + ';';
          spin.appendChild(bar);
        }
        ind.appendChild(spin);
        (document.body || document.documentElement).appendChild(ind);
        if (!document.getElementById('clp2r-kf')) {
          var st = document.createElement('style'); st.id = 'clp2r-kf';
          st.textContent = '@keyframes clp2r-spin{to{transform:rotate(360deg)}}';
          (document.head || document.documentElement).appendChild(st);
        }
      }
      window.__clPTR = {
        // progress 0..1 during the pull: slide in, grow, wind, then settle +
        // darken the spokes at the limit ("release to refresh").
        show: function (progress) {
          build();
          var p = Math.max(0, Math.min(progress, 1));
          spin.style.animation = 'none';
          spin.style.filter = (p >= 1) ? 'brightness(.65)' : 'none';
          ind.style.opacity = String(Math.min(1, p * 1.25));
          ind.style.transform =
            'translate(-50%,' + (-30 + p * 72) + 'px) scale(' + (0.6 + p * 0.4).toFixed(3) +
            ') rotate(' + (p * 300) + 'deg)';
        },
        hide: function () {
          if (!ind) return;
          ind.style.opacity = '0';
          ind.style.transform = 'translate(-50%,-30px) scale(.6)';
        },
        // armed + released: free-spin (ticky 12-step, like macOS) until the
        // reload replaces the page.
        fire: function () {
          build();
          ind.style.opacity = '1';
          ind.style.transform = 'translate(-50%,42px) scale(1)';
          spin.style.filter = 'none';
          spin.style.animation = 'clp2r-spin .8s steps(12,end) infinite';
        }
      };
    })();
    """
}
