import Cocoa
import WebKit

// MARK: - Status bubble (hover link preview)
//
// Bottom-left pill that shows a link's target URL on hover — the standard
// browser affordance Chromeless was missing. Styled like Helium's: rounded
// (radius 16), 1px hairline, omnibox-container fill. Never eats mouse events, so
// the page underneath stays fully interactive.

final class StatusBubble: NSView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 0.98).cgColor
        label.font = .systemFont(ofSize: 11.5)
        label.textColor = .secondaryLabelColor
        // Tail truncation keeps the important domain head readable (a bare domain
        // never truncates); middle truncation made short URLs look broken.
        label.lineBreakMode = .byTruncatingTail
        label.cell?.usesSingleLineMode = true
        (label.cell as? NSTextFieldCell)?.truncatesLastVisibleLine = true
        addSubview(label)
        alphaValue = 0
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The bubble must never intercept page mouse events (Helium: accept_events
    /// = false) — otherwise it would swallow clicks on links it's previewing.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    /// Intrinsic width for the current text, capped at `maxWidth` (Helium caps at
    /// ⅓ of the content width). H-padding 10 each side.
    func fittingWidth(maxWidth: CGFloat) -> CGFloat {
        // Measure with the actual font so short URLs get a bubble wide enough to
        // show in full (no spurious truncation).
        let w = (label.stringValue as NSString).size(withAttributes: [.font: label.font as Any]).width
        return max(80, min(maxWidth, ceil(w) + 22))
    }

    func layoutLabel() {
        label.frame = NSRect(x: 10, y: (bounds.height - 15) / 2, width: bounds.width - 20, height: 15)
    }
}

/// Routes link-hover messages from any web view to the controller of the window
/// that view lives in. Shared singleton so `WebViewFactory` can wire every tab's
/// content controller without needing a controller reference at creation time.
final class StatusBubbleRelay: NSObject, WKScriptMessageHandler {
    static let shared = StatusBubbleRelay()

    static let userScript = WKUserScript(source: """
        (function () {
          if (window.__chromelessLinkHover) return;
          window.__chromelessLinkHover = true;
          function hrefOf(el) {
            while (el && el.nodeType === 1) {
              if (el.tagName === 'A' && el.href) return el.href;
              el = el.parentElement;
            }
            return null;
          }
          var last = null;
          document.addEventListener('mouseover', function (e) {
            var h = hrefOf(e.target);
            if (h && h !== last) { last = h; window.webkit.messageHandlers.linkHover.postMessage(h); }
          }, true);
          document.addEventListener('mouseout', function (e) {
            if (hrefOf(e.target)) { last = null; window.webkit.messageHandlers.linkHover.postMessage(''); }
          }, true);
        })();
        """, injectionTime: .atDocumentStart, forMainFrameOnly: false)

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let href = message.body as? String,
              let wc = message.webView?.window?.windowController as? BrowserWindowController else { return }
        if href.isEmpty { wc.hideStatusBubble() } else { wc.showStatusBubble(href) }
    }
}
