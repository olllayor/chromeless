import Cocoa
import CoreLocation
import LocalAuthentication
import Security
import WebKit

final class SuggestionRow: NSView {
    let index: Int
    private let clickAction: Selector
    private weak var clickTarget: AnyObject?

    init(index: Int, target: AnyObject?, action: Selector) {
        self.index = index
        self.clickAction = action
        self.clickTarget = target
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseUp(with event: NSEvent) {
        _ = clickTarget?.perform(clickAction, with: self)
    }
}
// MARK: - Views

final class BrowserWebView: WKWebView {
    var onEscape: (() -> Bool)?
    var onTabCycle: ((Bool) -> Void)?
    var onTabSwitch: ((Int) -> Void)?
    var onImageCopied: (() -> Void)?
    var onLinkCopied: (() -> Void)?

    // A freshly-added WKWebView asks to become first responder as soon as it's
    // displayed, which races with (and can override) an explicit focus of the
    // address bar right after creating a blank tab. Setting this suppresses
    // that grab so the caller's own makeFirstResponder call sticks.
    var suppressAutoFocus = false

    override func becomeFirstResponder() -> Bool {
        if suppressAutoFocus { return false }
        return super.becomeFirstResponder()
    }

    // Detect the native "Copy Image"/"Copy Link" context-menu commands so we can
    // surface a confirmation toast. WebKit performs the copy itself; we wrap the
    // item's action to fire our callback afterwards.
    private weak var wrappedTarget: AnyObject?
    private var wrappedAction: Selector?
    private var wrappedIsImage = false

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        for item in menu.items {
            // WebKit tags these with stable WKMenuItemIdentifier* identifiers;
            // fall back to the private action selector name.
            let ident = item.identifier?.rawValue ?? ""
            let sel = item.action.map { NSStringFromSelector($0) } ?? ""
            let isImage = ident.localizedCaseInsensitiveContains("CopyImage")
                || sel.localizedCaseInsensitiveContains("copyImage")
            let isLink = ident.localizedCaseInsensitiveContains("CopyLink")
                || sel.localizedCaseInsensitiveContains("copyLink")
            guard isImage || isLink else { continue }
            wrappedTarget = item.target
            wrappedAction = item.action
            wrappedIsImage = isImage
            item.target = self
            item.action = #selector(handleWrappedCopy(_:))
            break
        }
    }

    @objc private func handleWrappedCopy(_ sender: Any?) {
        if let t = wrappedTarget, let a = wrappedAction, t.responds(to: a) {
            _ = t.perform(a, with: sender)
        }
        (wrappedIsImage ? onImageCopied : onLinkCopied)?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, // Esc
           event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
           window?.styleMask.contains(.fullScreen) != true,
           fullscreenState == .notInFullscreen,
           onEscape?() == true {
            return
        }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 48, mods.contains(.control) {
            onTabCycle?(mods.contains(.shift))
            return
        }
        if let index = Self.tabSwitchIndex(for: event, mods: mods) {
            onTabSwitch?(index)
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 48, mods.contains(.control) {
            onTabCycle?(mods.contains(.shift))
            return true
        }
        if let index = Self.tabSwitchIndex(for: event, mods: mods) {
            onTabSwitch?(index)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// ⌘1–⌘9 → tab index 0–8, matched on the actual digit character so it doesn't
    /// collide with `=`/`-` (keyCodes 24/27) and works regardless of layout.
    /// Requires *exactly* Command (no Shift), so ⌘= (zoom in) is left for the menu.
    private static func tabSwitchIndex(for event: NSEvent, mods: NSEvent.ModifierFlags) -> Int? {
        guard mods == .command,
              let ch = event.charactersIgnoringModifiers,
              ch.count == 1, let digit = Int(ch), digit >= 1, digit <= 9
        else { return nil }
        return digit - 1
    }

    // ⌘-drag anywhere moves the window; mouse buttons 4/5 go back/forward.
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            window?.performDrag(with: event)
            return
        }
        super.mouseDown(with: event)
    }
    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 3, canGoBack { goBack(); return }
        if event.buttonNumber == 4, canGoForward { goForward(); return }
        super.otherMouseUp(with: event)
    }
}

final class LayoutReportingView: NSView {
    var onLayout: (() -> Void)?
    override func layout() {
        super.layout()
        onLayout?()
    }
}

/// Holds HUD/find-bar overlays above WKWebView; clicks pass through empty areas to the page.
final class OverlayRootView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// Window that protects the address bar's focus: while the URL field is being
/// edited, a web page calling `element.focus()` (common on login pages that
/// autofocus a field, or re-render) must not steal first responder mid-type.
/// A genuine user click into the page is still honored so the guard never traps
/// focus in the URL bar.
final class BrowserWindow: NSWindow {
    var isEditingURLField = false
    var currentWebView: (() -> NSView?)?
    // Begin/end-editing notifications don't reliably fire for the URL field, so
    // `isEditingURLField` alone can be stale (false) mid-edit — which disarms the
    // steal guard below and lets a page's element.focus() kill the field editor
    // on the first keystroke. This closure reports the LIVE first-responder state
    // (the field editor is still the outgoing responder when a steal arrives), so
    // the guard arms whenever the URL field truly owns focus.
    var isEditingURLFieldLive: (() -> Bool)?

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        if isEditingURLFieldLive?() ?? isEditingURLField {
            // A loaded page can call element.focus() on any event (commonly the
            // first keystroke), which asks to move first responder off the URL
            // field's editor. Depending on how WebKit declines, AppKit routes
            // this either to the web view, to `nil`, or to the window itself —
            // all of which crater the field editor and kill typing. Deny every
            // such steal unless it's a genuine user click into the page.
            let stealsFocus: Bool = {
                if responder == nil || responder === self { return true }
                if let v = responder as? NSView, let wv = currentWebView?(),
                   v === wv || v.isDescendant(of: wv) { return true }
                return false
            }()
            if stealsFocus {
                let userClick: Bool = {
                    switch NSApp.currentEvent?.type {
                    case .leftMouseDown, .leftMouseUp, .rightMouseDown, .otherMouseDown: return true
                    default: return false
                    }
                }()
                if !userClick { return false }
            }
        }
        return super.makeFirstResponder(responder)
    }
}
