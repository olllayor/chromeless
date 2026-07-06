import Cocoa
import CoreLocation
import LocalAuthentication
import Security
import WebKit

// MARK: - Browser window

final class BrowserWindowController: NSWindowController, NSWindowDelegate,
    WKNavigationDelegate, WKUIDelegate, NSTextFieldDelegate, NSMenuItemValidation,
    NSGestureRecognizerDelegate {

    var webView: BrowserWebView
    let tabManager = TabManager()
    /// Split view (Helium 5.1): two tabs shown side-by-side as rounded panes.
    /// `nil` = normal single-pane. The active tab is always one of the pair;
    /// selecting any third tab exits the split.
    private var splitPair: (Tab, Tab)?
    /// Left pane's share of the split width; draggable via the divider strip.
    private var splitRatio: CGFloat = 0.5
    private let splitDivider = SplitDividerView()
    private let overlayRoot = OverlayRootView()
    private let progressBar = NSView()
    private let hud = NSVisualEffectView()
    private let hudBacking = NSView()
    private let hudField = NSTextField()
    private let toastView = NSVisualEffectView()
    private let toastLabel = NSTextField(labelWithString: "")
    private let toastIcon = NSImageView()
    private let toastStack = NSStackView()
    private let autofillBanner = NSVisualEffectView()
    private let autofillIcon = NSImageView()
    private let autofillLabel = NSTextField(labelWithString: "")
    private let autofillStack = NSStackView()
    private var autofillHide: DispatchWorkItem?
    private var observations: [NSKeyValueObservation] = []
    private var tabItemObservations: [NSKeyValueObservation] = []
    private var tabItemViews: [TabBarItem] = []
    private var tabWidthConstraints: [NSLayoutConstraint] = []
    private var mouseMonitor: Any?
    private var snapJob: SnapJob?
    private var toastHide: DispatchWorkItem?
    private let statusBubble = StatusBubble()
    private var statusBubbleHide: DispatchWorkItem?
    private var lastProgress: CGFloat = 0
    private var onStartPage = false
    private var lastHoveredButton: NSButton?
    var onClose: (() -> Void)?
    private let findBar = NSVisualEffectView()
    private let findField = NSTextField()
    private let findPrevButton = NSButton()
    private let findNextButton = NSButton()
    private let findCloseButton = NSButton()
    private let findStatusLabel = NSTextField(labelWithString: "")
    private var lastFindQuery: String?
    private var hudW: CGFloat = 620
    private let downloadsOverlay = NSVisualEffectView()
    private let downloadsList = DownloadsListView()
    private let downloadsScrollView = NSScrollView()
    private let tabBarHeight: CGFloat = 31
    private let toolbarHeight: CGFloat = 34
    private let tabToolbarOverlap: CGFloat = 0
    private let centeredLocationBarMaxWidth: CGFloat = 700
    private let trafficLightInset: CGFloat = 78
    // Manual ⌘-toggle override (View ▸ Hide Tab Bar). Independent of auto-hide.
    private var manualTabBarHidden = false
    // Helium "dynamic" layout: a lone tab hides the strip entirely (pure
    // toolbar + content); opening a 2nd tab brings it back. Default on.
    private var autoHideSingleTab: Bool {
        UserDefaults.standard.object(forKey: "AutoHideSingleTab") as? Bool ?? true
    }
    /// The tab strip is hidden when manually toggled off, or when auto-hide is on
    /// and only one tab is open. Drives chrome height + toolbar top inset.
    private var tabBarHidden: Bool {
        manualTabBarHidden || (autoHideSingleTab && tabManager.count <= 1)
    }
    private var chromeTopHeight: CGFloat {
        (tabBarHidden ? 0 : tabBarHeight) + toolbarHeight - tabToolbarOverlap
    }

    // MARK: Zen (Frameless) mode
    // All top chrome slides out of view for edge-to-edge content; it reveals when
    // the cursor hits the top edge and slides away shortly after. Helium's
    // "Frameless mode". Default off — when off, zenSlide stays 1 and every zen
    // branch is a no-op, so normal chrome is untouched.
    private var zenModeEnabled: Bool { UserDefaults.standard.bool(forKey: "ZenMode") }
    private var zenTopPinned: Bool { UserDefaults.standard.bool(forKey: "ZenTopChromePinned") }
    /// 0 = chrome fully hidden (slid above the top edge), 1 = fully shown.
    private var zenSlide: CGFloat = 1
    private var zenRevealed = true
    private var zenHoverExitTimer: Timer?
    private var zenAnimTimer: Timer?
    // Exact Helium constants.
    private let zenTriggerBand: CGFloat = 6      // top hot-zone thickness
    private let zenHoverLeeway: CGFloat = 8      // slop around revealed chrome
    private let zenRevealDuration: TimeInterval = 0.2
    private let zenHoverExitGrace: TimeInterval = 0.15
    private let tabBar = NSVisualEffectView()
    private let tabBarSeparator = NSView()
    private let tabStack = NSStackView()
    private let toolbarBar = NSVisualEffectView()
    private let locationBar = NSVisualEffectView()
    private let locationIcon = NSButton()
    private var siteSettingsPopover: NSPopover?
    private var siteSettingsOrigin: String?
    private let backBtn = NSButton()
    private let forwardBtn = NSButton()
    private let reloadBtn = NSButton()
    private let downloadsButton = DownloadsToolbarButton()
    // Helium-style profile avatar at the toolbar's right edge: a round chip
    // tinted with the current tab's container color. Opens the account switcher.
    private let identityAvatar = HoverIconButton(frame: .zero)
    // Right-edge space reserved in the toolbar for the avatar + downloads button,
    // so the centered location bar never overlaps them on narrow windows.
    private var toolbarRightInset: CGFloat = 0
    private let urlField = NSTextField()
    private var suggestionsView = NSVisualEffectView()
    private var suggestionsBacking = NSView()
    /// Plain container; rows are laid out with explicit frames in
    /// `layoutSuggestionRows()` (an NSStackView collapses them without
    /// per-row size constraints).
    private let suggestionsStack = NSView()
    struct Suggestion {
        let url: String       // where the row navigates
        let title: String     // primary text
        let subtitle: String  // trailing text: pretty URL, or "<Engine> Search"
        let isSearch: Bool     // search-engine phrase vs. a real page
    }
    private var suggestionItems: [Suggestion] = []
    private var selectedSuggestionIndex: Int = -1
    /// Bumped on each keystroke so stale async engine-suggestion replies are dropped.
    private var suggestionQueryToken = 0

    init(url: URL?, size: NSSize?, snap: SnapJob?, isPrimary: Bool) {
        let conf = WebViewFactory.makeConfiguration()
        webView = BrowserWebView(frame: .zero, configuration: conf)
        snapJob = snap

        let contentSize = size ?? NSSize(width: 1160, height: 760)
        let window = BrowserWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        super.init(window: window)
        window.currentWebView = { [weak self] in self?.webView }
        window.isEditingURLFieldLive = { [weak self] in self?.isURLFieldEditingNow ?? false }

        window.title = "Chromeless"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 320, height: 220)
        window.backgroundColor = NSColor(calibratedWhite: 0.04, alpha: 1)
        window.appearance = NSAppearance(named: .darkAqua)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.acceptsMouseMovedEvents = true
        window.delegate = self
        setTrafficLights(visible: true)

        let container = LayoutReportingView(frame: NSRect(origin: .zero, size: contentSize))
        container.onLayout = { [weak self] in self?.layoutOverlays() }
        window.contentView = container

        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        webView.onEscape = { [weak self] in self?.escapeToStart() ?? false }
        webView.onTabCycle = { [weak self] backward in
            self?.tabManager.cycleMRU(backward: backward)
            if let tab = self?.tabManager.current {
                self?.switchToTab(tab)
            }
        }
        webView.onTabSwitch = { [weak self] index in
            guard let self, index < self.tabManager.count else { return }
            self.switchToTab(self.tabManager.tabs[index])
        }
        webView.onImageCopied = { [weak self] in self?.confirmToast("Image copied", symbol: "photo") }
        webView.onLinkCopied = { [weak self] in self?.confirmToast("Link copied", symbol: "link") }
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.underPageBackgroundColor = NSColor(calibratedWhite: 0.04, alpha: 1)
        if #available(macOS 13.3, *) { webView.isInspectable = true }

        overlayRoot.wantsLayer = true
        overlayRoot.frame = container.bounds
        overlayRoot.autoresizingMask = [.width, .height]
        container.addSubview(overlayRoot)

        container.addSubview(webView, positioned: .below, relativeTo: overlayRoot)

        buildChrome(in: container)
        observeWebView()

        if isPrimary && snap == nil {
            // Remember the size across launches (via the autosave name)…
            window.setFrameUsingName("ChromelessMain")
            window.setFrameAutosaveName("ChromelessMain")
        } else if let key = NSApp.keyWindow {
            window.setFrameTopLeftPoint(NSPoint(x: key.frame.minX + 30, y: key.frame.maxY - 30))
        } else {
            window.center()
        }
        if let size { window.setContentSize(size) }
        // …but always open the primary window centered on the active screen
        // (Helium: center-window-on-launch, instead of restoring last position).
        // Exact geometric centering, matching Helium — NSWindow.center() biases
        // the window slightly above center.
        if isPrimary && snap == nil, let scr = window.screen ?? NSScreen.main {
            let v = scr.visibleFrame
            let f = window.frame
            window.setFrameOrigin(NSPoint(x: v.minX + (v.width - f.width) / 2,
                                          y: v.minY + (v.height - f.height) / 2))
        }

        installMouseMonitor()

        let firstTab = Tab(webView: webView)
        tabManager.tabs.append(firstTab)
        tabManager.selectIndex(0)
        tabManager.onTabsChanged = { [weak self] in self?.refreshTabBar() }
        refreshTabBar()

        // If zen was left on across launches, start with the chrome hidden.
        if zenModeEnabled {
            zenRevealed = zenTopPinned
            zenSlide = zenTopPinned ? 1 : 0
            layoutOverlays()
        }

        if let url { navigate(to: url) } else { loadStartPage() }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Chrome (what little there is)

    private func setTrafficLights(visible: Bool) {
        for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            window?.standardWindowButton(kind)?.isHidden = !visible
        }
    }

    private var trafficLightsDimmed: Bool?
    private func dimTrafficLights(_ dim: Bool) {
        // In zen mode the traffic lights fade with the chrome (alpha = zenSlide),
        // so leave them alone here.
        guard !zenModeEnabled else { return }
        // Called on every mouseMoved — skip the layer writes unless the state
        // actually flips, so hovering the page doesn't thrash three buttons.
        guard trafficLightsDimmed != dim else { return }
        trafficLightsDimmed = dim
        for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            window?.standardWindowButton(kind)?.alphaValue = dim ? 0.5 : 1.0
        }
    }

    private var isFullScreen: Bool { window?.styleMask.contains(.fullScreen) ?? false }

    private func installMouseMonitor() {
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            if !self.hud.isHidden {
                let p = self.window!.contentView!.convert(event.locationInWindow, from: nil)
                if !self.hud.frame.contains(p) { self.hideHUD() }
            }
            if event.type == .mouseMoved {
                let p = self.window!.contentView!.convert(event.locationInWindow, from: nil)
                if self.zenModeEnabled { self.updateZenReveal(cursorY: p.y) }
                let nearTopEdge = p.y > self.window!.contentView!.bounds.height - self.chromeTopHeight - 8
                let nearLeftCorner = p.x < 96
                self.dimTrafficLights(!(nearTopEdge || nearLeftCorner))

                // Nav button hover
                let navBtns = [self.backBtn, self.forwardBtn, self.reloadBtn, self.downloadsButton]
                let hit = navBtns.first { btn in
                    let f = btn.convert(btn.bounds, to: nil)
                    return f.contains(p) && !btn.isHidden
                }
                if hit !== self.lastHoveredButton {
                    self.lastHoveredButton?.layer?.animateBackground(to: .clear)
                    self.lastHoveredButton = hit
                    hit?.layer?.animateBackground(to: NSColor.white.withAlphaComponent(0.12).cgColor)
                }
            } else if event.type == .leftMouseDown {
                // Clear nav hover on click
                if let last = self.lastHoveredButton {
                    last.layer?.animateBackground(to: .clear)
                    self.lastHoveredButton = nil
                }
                // Split view: clicking the unfocused pane moves focus to it
                // (omnibox, tab highlight, border emphasis). The event still
                // reaches the page, so the click also lands where aimed.
                if let (l, r) = self.splitPair {
                    let p = self.window!.contentView!.convert(event.locationInWindow, from: nil)
                    let inactive = self.tabManager.current?.id == l.id ? r : l
                    if inactive.webView.frame.contains(p) {
                        self.switchToTab(inactive)
                        self.refreshTabBar()
                    }
                }
            }
            return event
        }
    }

    // MARK: Find Bar

    @objc func showFindBar(_ sender: Any?) {
        if !hud.isHidden { hideHUD() }
        findField.stringValue = lastFindQuery ?? ""
        findBar.isHidden = false
        layoutOverlays()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            findBar.animator().alphaValue = 1
        }
        findField.selectText(nil)
    }

    @objc func hideFindBar(_ sender: Any?) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            self.findBar.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.findBar.isHidden = true
            self.window?.makeFirstResponder(self.webView)
        })
    }

    @objc func findNext(_ sender: Any?) {
        guard let query = findField.stringValue.nilIfEmpty else { return }
        lastFindQuery = query
        let config = WKFindConfiguration()
        config.backwards = false
        config.wraps = true
        webView.find(query, configuration: config) { [weak self] result in
            DispatchQueue.main.async {
                self?.findStatusLabel.stringValue = result.matchFound ? "✓" : "✗"
            }
        }
    }

    @objc func findPrev(_ sender: Any?) {
        guard let query = findField.stringValue.nilIfEmpty else { return }
        lastFindQuery = query
        let config = WKFindConfiguration()
        config.backwards = true
        config.wraps = true
        webView.find(query, configuration: config) { [weak self] result in
            DispatchQueue.main.async {
                self?.findStatusLabel.stringValue = result.matchFound ? "✓" : "✗"
            }
        }
    }

    @objc private func runFind() {
        guard let query = findField.stringValue.nilIfEmpty else {
            findStatusLabel.stringValue = ""
            return
        }
        lastFindQuery = query
        let config = WKFindConfiguration()
        config.backwards = false
        config.wraps = true
        webView.find(query, configuration: config) { [weak self] result in
            DispatchQueue.main.async {
                self?.findStatusLabel.stringValue = result.matchFound ? "✓" : "✗"
            }
        }
    }

    // MARK: Downloads Overlay

    @objc func toggleDownloads(_ sender: Any?) {
        downloadsOverlay.isHidden = !downloadsOverlay.isHidden
        if !downloadsOverlay.isHidden {
            refreshDownloads()
            downloadsOverlay.alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                downloadsOverlay.animator().alphaValue = 1
            }
        }
    }

    /// Fires on every DownloadManager change: keep the toolbar button's
    /// visibility + progress ring current, and rebuild the panel if it's open.
    private func downloadsDidUpdate() {
        let wasHidden = downloadsButton.isHidden
        // Only a visibility flip needs a full relayout (it shifts the location
        // bar inset); byte-progress ticks just repaint the ring / open panel.
        if wasHidden == DownloadManager.shared.hasItems {
            layoutOverlays()
        }
        downloadsButton.setProgress(DownloadManager.shared.activeProgress)
        if !downloadsOverlay.isHidden { refreshDownloads() }
        if wasHidden && !downloadsButton.isHidden { popDownloadsButton() }
    }

    /// Subtle scale-pop when the downloads button first appears.
    private func popDownloadsButton() {
        guard let layer = downloadsButton.layer else { return }
        let pop = CABasicAnimation(keyPath: "transform.scale")
        pop.fromValue = 0.6
        pop.toValue = 1.0
        pop.duration = 0.22
        pop.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(pop, forKey: "pop")
    }

    @objc func addBookmark(_ sender: Any?) {
        guard let url = webView.url, url.absoluteString != "about:blank" else {
            showToast("Can't bookmark this page")
            return
        }
        let alert = NSAlert()
        alert.messageText = "Add Bookmark"
        alert.informativeText = url.absoluteString
        let titleField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        titleField.stringValue = webView.title ?? ""
        alert.accessoryView = titleField
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            BookmarkStore.shared.addBookmark(url: url.absoluteString, title: titleField.stringValue)
            showToast("Bookmark added")
        }
    }

    /// The identity a live web view belongs to (its tab's container).
    func identityID(for webView: WKWebView) -> UUID {
        tabManager.tabs.first { $0.webView === webView }?.identityID ?? IdentityStore.defaultID
    }

    /// Open a new tab. `identityID` picks the account container: nil means the
    /// built-in default (fresh cmd-T / + button); link-open paths pass the opener
    /// tab's identity so a Work page keeps spawning Work tabs.
    func newTab(url: URL? = nil, background: Bool = false, identityID: UUID? = nil) {
        let identity = identityID.flatMap { IdentityStore.shared.identity($0) }
            ?? IdentityStore.shared.defaultIdentity
        let wv = WebViewFactory.dequeueWebView(for: identity)
        let tab = Tab(webView: wv)
        tab.identityID = identity.id
        if UserDefaults.standard.bool(forKey: "NewTabNextToActive") {
            let insertIndex = tabManager.currentIndex + 1
            tabManager.tabs.insert(tab, at: insertIndex)
        } else {
            tabManager.tabs.append(tab)
        }
        // Background (cmd-click): load without stealing focus from the current
        // tab; just refresh the strip so the new tab appears.
        if background, let url {
            wv.load(URLRequest(url: url))
            refreshTabBar()
            return
        }
        switchToTab(tab)
        if let url {
            wv.load(URLRequest(url: url))
        } else {
            loadStartPage()
            // Blank new tab → drop the caret straight into the address bar so the
            // user can type immediately (Chrome/Helium behaviour). Suppress the
            // webview's own first-responder grab first so our focus sticks
            // regardless of how long WebKit takes to spin up.
            wv.suppressAutoFocus = true
            focusURLField()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { wv.suppressAutoFocus = false }
        }
    }

    func closeCurrentTab() {
        if let cur = tabManager.current { dissolveSplitIfInvolved(cur) }
        ClosedTabStore.push(tabManager.current?.url)
        if tabManager.count <= 1 {
            let oldTab = tabManager.tabs.first
            oldTab?.webView.removeFromSuperview()
            let newTab = Tab(webView: WebViewFactory.dequeueWebView())
            tabManager.replaceAll(with: newTab)
            switchToTab(newTab)
            loadStartPage()
            return
        }
        // Pull the dying web view out of the hierarchy explicitly — switchToTab
        // only removes the *new* current tab's view (a no-op), so without this
        // the closed tab's view (and its WebContent process) leaks in the
        // container, hidden under the next tab.
        tabManager.current?.webView.removeFromSuperview()
        tabManager.closeCurrent()
        switchToTab(tabManager.tabs[tabManager.currentIndex])
    }

    // NSTextField's NSControlTextEditingDelegate begin/end-editing notifications
    // don't reliably fire for every focus path here (observed: end fires
    // without a matching begin), so isEditingURLField can't be trusted alone.
    // Check the live first responder instead: true whenever urlField or its
    // attached field editor currently owns keyboard focus.
    private var isURLFieldEditingNow: Bool {
        guard let fr = window?.firstResponder else { return false }
        if fr === urlField { return true }
        if let tv = fr as? NSTextView, tv.delegate as? NSObject === urlField { return true }
        return false
    }

    private var minimalAddressBar: Bool { UserDefaults.standard.bool(forKey: "MinimalAddressBar") }

    /// Bare host for the minimal address bar — drops a leading "www.".
    private func displayHost(_ url: URL) -> String {
        var h = url.host ?? url.absoluteString
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h
    }

    private func updateURLField() {
        // Never clobber the field while the user is actively editing it — an
        // async title/url KVO callback landing mid-edit would otherwise reset
        // stringValue and silently end the field editor session, kicking
        // first responder back to the window.
        guard !isURLFieldEditingNow else { return }
        if let url = webView.url, !onStartPage, url.absoluteString != "about:blank" {
            // Minimal address bar (Helium): show just the host when idle; the full
            // URL comes back on focus (see focusURLField). Off → full URL.
            urlField.stringValue = minimalAddressBar ? displayHost(url) : url.absoluteString
            // Minimal, centered omnibox (Helium). Focus handlers switch to
            // left-aligned (.natural) while the user is editing.
            urlField.alignment = .center
            // Persistent site-settings affordance (Chrome/Arc "tune" glyph)
            // instead of a passive lock — connection security still shown inside
            // the popover.
            locationIcon.image = NSImage(systemSymbolName: "slider.horizontal.3",
                                         accessibilityDescription: "Site settings")
            locationIcon.contentTintColor = .secondaryLabelColor
        } else {
            urlField.stringValue = ""
            // Helium centers the placeholder on the new-tab omnibox. A centered
            // paragraph style is required — NSTextField.alignment alone does not
            // apply to an attributed placeholder string.
            urlField.alignment = .center
            urlField.placeholderAttributedString = ChromeFont.placeholder(
                "Search Google or type a URL",
                font: ChromeFont.urlField,
                color: .secondaryLabelColor,
                alignment: .center)
            locationIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Search")
            locationIcon.contentTintColor = .secondaryLabelColor
        }
    }

    private func centeredLocationBarFrame(windowWidth: CGFloat, toolbarY: CGFloat) -> NSRect {
        let barH = toolbarHeight - 8
        let barY = toolbarY + 4
        let navLeading: CGFloat = tabBarHidden ? trafficLightInset : 12
        let navBtnSize: CGFloat = 28
        let navBtnGap: CGFloat = 2
        let navWidth = navBtnSize * 3 + navBtnGap * 2
        let slotX = navLeading + navWidth + 10
        let slotMaxX = windowWidth - 12 - toolbarRightInset

        guard UserDefaults.standard.object(forKey: "CenteredLocationBar") as? Bool ?? true else {
            return NSRect(x: slotX, y: barY, width: max(260, slotMaxX - slotX), height: barH)
        }

        let reduction: CGFloat
        if windowWidth >= 1000 { reduction = windowWidth * 0.12 }
        else if windowWidth >= 800 { reduction = windowWidth * 0.10 }
        else if windowWidth >= 600 { reduction = windowWidth * 0.05 }
        else { reduction = 0 }

        let slotWidth = max(260, slotMaxX - slotX)
        let barWidth = min(centeredLocationBarMaxWidth, max(260, slotWidth - reduction))

        var barX = (windowWidth - barWidth) / 2
        let minX = slotX
        let maxX = slotMaxX - barWidth
        if barX < minX { barX = minX }
        if barX > maxX { barX = max(minX, (slotX + slotMaxX - barWidth) / 2) }

        return NSRect(x: barX, y: barY, width: barWidth, height: barH)
    }

    /// Frame + corner-round the web view. When the rounded-frame setting is on
    /// (Helium's kHeliumRoundedFrame) the content floats as a card inset from the
    /// chrome with continuous-rounded corners; off, it fills edge-to-edge.
    // macOS 26 (Tahoe) raised the system window-corner radius from 12 to 17;
    // match it so the inset web content's rounding stays consistent with the
    // native window chrome around it (Helium's GetSystemWindowRadius()).
    private static let systemWindowRadius: CGFloat = {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 ? 17 : 12
    }()

    func frameWebView(_ wv: WKWebView) {
        guard let b = window?.contentView?.bounds else { return }
        let contentTop = zenModeEnabled ? 0 : chromeTopHeight
        wv.wantsLayer = true
        wv.autoresizingMask = [.width, .height]
        wv.layer?.cornerCurve = .continuous
        wv.layer?.masksToBounds = true

        let allCorners: CACornerMask = [.layerMinXMinYCorner, .layerMaxXMinYCorner,
                                        .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        let bottomCorners: CACornerMask = [.layerMinXMinYCorner, .layerMaxXMinYCorner]

        // Split view: both panes are rounded cards regardless of the
        // rounded-frame setting; the active pane gets a brighter edge.
        if let (l, r) = splitPair, wv === l.webView || wv === r.webView {
            let geo = splitGeometry(in: b, contentTop: contentTop)
            wv.autoresizingMask = []   // explicit frames; layoutOverlays tracks resize
            wv.frame = wv === l.webView ? geo.left : geo.right
            wv.layer?.cornerRadius = 10
            wv.layer?.maskedCorners = allCorners
            wv.layer?.borderWidth = 1
            let isActive = wv === tabManager.current?.webView
            wv.layer?.borderColor = NSColor.white.withAlphaComponent(isActive ? 0.22 : 0.07).cgColor
            return
        }

        if ChromeTheme.roundedFrame {
            // "Rounded frame" ON: web content floats as a rounded card, inset
            // uniformly from the window + chrome, all four corners rounded, with a
            // hairline edge so the moat around it reads as deliberate (not a seam).
            let inset: CGFloat = 8
            wv.frame = NSRect(x: inset, y: inset,
                              width: b.width - inset * 2,
                              height: b.height - contentTop - inset * 2)
            wv.layer?.cornerRadius = 10
            wv.layer?.maskedCorners = allCorners
            wv.layer?.borderWidth = 1
            wv.layer?.borderColor = NSColor.white.withAlphaComponent(0.07).cgColor
        } else {
            // OFF: fill edge-to-edge, flush under the chrome; only the bottom
            // (window-edge) corners round so nothing pokes past the window shape.
            wv.frame = NSRect(x: 0, y: 0, width: b.width, height: b.height - contentTop)
            wv.layer?.cornerRadius = Self.systemWindowRadius
            wv.layer?.maskedCorners = bottomCorners
            wv.layer?.borderWidth = 0
        }
    }

    /// Re-apply theme-driven chrome (rounded frame, accent) after a settings change.
    func applyChromeSettings() {
        layoutOverlays()
        progressBar.layer?.backgroundColor = ChromeTheme.accent.cgColor
        if urlField.currentEditor() != nil {
            locationBar.layer?.borderColor = ChromeTheme.accent.withAlphaComponent(0.45).cgColor
        }
        // Reflect a minimal-address-bar toggle immediately.
        updateURLField()
    }

    private func switchToTab(_ tab: Tab) {
        guard let container = window?.contentView else { return }
        hideStatusBubble()
        // Selecting a tab outside the split pair leaves split view; the
        // partner pane's view goes, the normal single-pane flow takes over.
        if let (l, r) = splitPair, tab.id != l.id, tab.id != r.id {
            exitSplitView()
        }
        let inSplit: Bool = {
            guard let (l, r) = splitPair else { return false }
            return tab.id == l.id || tab.id == r.id
        }()
        if inSplit {
            // Both pane views stay put — just move focus/emphasis.
            tabManager.select(tab)
            layoutOverlays()
        } else {
            if let current = tabManager.current {
                current.webView.removeFromSuperview()
            }
            tabManager.select(tab)
            tab.webView.alphaValue = 0
            container.addSubview(tab.webView, positioned: .below, relativeTo: overlayRoot)
            frameWebView(tab.webView)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                tab.webView.animator().alphaValue = 1
            }
        }
        webView = tab.webView
        window?.title = tab.title.isEmpty ? "Chromeless" : tab.title
        observations.removeAll()
        observations = [
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in
                self?.progressChanged(wv.estimatedProgress)
            },
            // Title changes only need the window title — each TabBarItem keeps
            // its own live title observer (see refreshTabBar), so a full strip
            // rebuild here (views + observers + favicon refetch for every tab,
            // several times per page load) was pure waste.
            webView.observe(\.title) { [weak self] wv, _ in
                let t = wv.title ?? ""
                self?.window?.title = t.isEmpty ? "Chromeless" : t
            },
            webView.observe(\.url) { [weak self] wv, _ in
                if let u = wv.url, u.scheme == "https" || u.scheme == "http" {
                    UserDefaults.standard.set(u.absoluteString, forKey: "LastURL")
                }
                DispatchQueue.main.async { self?.updateURLField() }
            },
        ]
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.onEscape = { [weak self] in self?.escapeToStart() ?? false }
        webView.onTabCycle = { [weak self] backward in
            self?.tabManager.cycleMRU(backward: backward)
            if let tab = self?.tabManager.current {
                self?.switchToTab(tab)
            }
        }
        webView.onTabSwitch = { [weak self] index in
            guard let self, index < self.tabManager.count else { return }
            self.switchToTab(self.tabManager.tabs[index])
        }
        webView.onImageCopied = { [weak self] in self?.confirmToast("Image copied", symbol: "photo") }
        webView.onLinkCopied = { [weak self] in self?.confirmToast("Link copied", symbol: "link") }
        updateURLField()
        updateIdentityAvatar()   // reflect the newly-selected tab's container
        backBtn.isEnabled = webView.canGoBack
        forwardBtn.isEnabled = webView.canGoForward
    }

    // MARK: Tab Bar

    @objc func toggleTabBar(_ sender: Any?) {
        manualTabBarHidden.toggle()
        layoutOverlays()
    }

    // MARK: Split view

    /// Pane + divider rects for the current ratio. Panes never shrink past
    /// 240pt; the divider occupies the 8pt gap between them.
    private func splitGeometry(in b: NSRect, contentTop: CGFloat) -> (left: NSRect, right: NSRect, divider: NSRect) {
        let inset: CGFloat = 8
        let gap: CGFloat = 8
        let total = max(0, b.width - inset * 2 - gap)
        let minPane: CGFloat = 240
        let leftW = total <= minPane * 2
            ? floor(total / 2)
            : max(minPane, min(total - minPane, floor(total * splitRatio)))
        let paneH = b.height - contentTop - inset * 2
        let left = NSRect(x: inset, y: inset, width: leftW, height: paneH)
        let right = NSRect(x: inset + leftW + gap, y: inset,
                           width: total - leftW, height: paneH)
        let divider = NSRect(x: inset + leftW, y: inset, width: gap, height: paneH)
        return (left, right, divider)
    }

    /// View ▸ Split View (⌘⇧E): pair the active tab with the next one in the
    /// strip; toggling while split exits.
    @objc func toggleSplitView(_ sender: Any?) {
        if splitPair != nil {
            exitSplitView()
            layoutOverlays()
            return
        }
        guard tabManager.count > 1, tabManager.current != nil else {
            showToast("Split view needs two tabs", symbol: "rectangle.split.2x1")
            return
        }
        let other = tabManager.tabs[(tabManager.currentIndex + 1) % tabManager.count]
        enterSplitView(with: other)
    }

    /// Pair `tab` with the active tab (active on the left).
    private func enterSplitView(with tab: Tab) {
        guard let container = window?.contentView,
              let cur = tabManager.current, cur.id != tab.id else { return }
        splitPair = (cur, tab)
        splitRatio = 0.5
        container.addSubview(tab.webView, positioned: .below, relativeTo: overlayRoot)
        // Divider strip in the gap: drag to rebalance the panes.
        splitDivider.onDrag = { [weak self] dx in
            guard let self, let b = self.window?.contentView?.bounds else { return }
            let total = max(1, b.width - 16 - 8)   // matches splitGeometry insets/gap
            self.splitRatio = min(0.9, max(0.1, self.splitRatio + dx / total))
            self.layoutOverlays()
        }
        container.addSubview(splitDivider, positioned: .below, relativeTo: overlayRoot)
        layoutOverlays()
        showToast("Split view — click a pane to focus it", symbol: "rectangle.split.2x1")
    }

    /// Tear down the split: keep the active tab's view (single-pane flow owns
    /// it), drop the partner pane's view.
    private func exitSplitView() {
        guard let (l, r) = splitPair else { return }
        splitPair = nil
        splitDivider.removeFromSuperview()
        let cur = tabManager.current
        for t in [l, r] where t.id != cur?.id { t.webView.removeFromSuperview() }
    }

    /// Close paths must dissolve the split first, or a closed partner pane's
    /// web view would be orphaned in the view hierarchy.
    private func dissolveSplitIfInvolved(_ tab: Tab) {
        guard let (l, r) = splitPair else { return }
        if tab.id == l.id || tab.id == r.id {
            exitSplitView()
            layoutOverlays()
        }
    }

    // MARK: Zen (Frameless) mode

    @objc func toggleZenMode(_ sender: Any?) {
        setZenMode(enabled: !zenModeEnabled)
    }

    func setZenMode(enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "ZenMode")
        zenAnimTimer?.invalidate(); zenAnimTimer = nil
        zenHoverExitTimer?.invalidate(); zenHoverExitTimer = nil
        if enabled {
            // Start hidden (revealed only if the user pinned the top bar).
            zenRevealed = zenTopPinned
            zenSlide = zenTopPinned ? 1 : 0
        } else {
            // Restore normal chrome + full-opacity, clickable traffic lights.
            zenRevealed = true
            zenSlide = 1
            for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
                let btn = window?.standardWindowButton(kind)
                btn?.alphaValue = 1
                btn?.isEnabled = true
            }
        }
        layoutOverlays()
        showToast(enabled ? "Frameless mode on — hover the top edge for chrome" : "Frameless mode off",
                  symbol: enabled ? "rectangle.dashed" : "rectangle.on.rectangle")
    }

    /// Reveal-vs-hide decision from the cursor's y (window coords, y-up).
    /// Called on every mouseMoved while zen is on.
    private func updateZenReveal(cursorY: CGFloat) {
        guard zenModeEnabled, let h = window?.contentView?.bounds.height else { return }
        // Force-show while pinned, editing the omnibox, or a popover/HUD is open.
        let forceShow = zenTopPinned || isURLFieldEditingNow
            || (siteSettingsPopover?.isShown ?? false) || !hud.isHidden
        let inTriggerBand = cursorY >= h - zenTriggerBand
        let overChrome = zenRevealed && cursorY >= h - chromeTopHeight - zenHoverLeeway
        if forceShow || inTriggerBand || overChrome {
            zenHoverExitTimer?.invalidate(); zenHoverExitTimer = nil
            revealZenChrome(true)
        } else if zenRevealed && zenHoverExitTimer == nil {
            // Left the chrome — hide after the short grace period.
            zenHoverExitTimer = Timer.scheduledTimer(withTimeInterval: zenHoverExitGrace, repeats: false) { [weak self] _ in
                self?.zenHoverExitTimer = nil
                self?.revealZenChrome(false)
            }
        }
    }

    private func revealZenChrome(_ reveal: Bool) {
        guard zenModeEnabled else { return }
        let target: CGFloat = reveal ? 1 : 0
        if zenRevealed == reveal && abs(zenSlide - target) < 0.001 { return }
        zenRevealed = reveal
        animateZen(to: target)
    }

    /// Drive zenSlide 0↔1 over zenRevealDuration, relaying out each frame.
    private func animateZen(to target: CGFloat) {
        zenAnimTimer?.invalidate()
        let start = zenSlide
        guard abs(target - start) > 0.001 else { zenSlide = target; layoutOverlays(); return }
        let begin = Date()
        zenAnimTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let e = min(1, Date().timeIntervalSince(begin) / self.zenRevealDuration)
            let eased = e * e * (3 - 2 * e)   // smoothstep, fast-out/slow-in feel
            self.zenSlide = start + (target - start) * CGFloat(eased)
            self.layoutOverlays()
            if e >= 1 {
                t.invalidate(); self.zenAnimTimer = nil
                self.zenSlide = target
                self.layoutOverlays()
            }
        }
    }

    /// Attaches a double-click recognizer to a chrome bar so double-clicking an
    /// empty area behaves like double-clicking a native titlebar. Clicks that
    /// land on a subview with its own recognizer (tabs, buttons) are unaffected.
    private func installTitlebarDoubleClick(on view: NSView) {
        let dbl = NSClickGestureRecognizer(target: self, action: #selector(titlebarDoubleClicked(_:)))
        dbl.numberOfClicksRequired = 2
        dbl.delaysPrimaryMouseButtonEvents = false
        view.addGestureRecognizer(dbl)
    }

    @objc private func titlebarDoubleClicked(_ sender: NSClickGestureRecognizer) {
        guard let window = window else { return }
        // Honour System Settings ▸ Desktop & Dock ▸ "Double-click a window's
        // title bar to". Default (unset) is Zoom/Maximize.
        let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")
        switch action {
        case "Minimize":
            window.miniaturize(nil)
        case "None":
            break
        default: // "Maximize", legacy "Zoom", or unset
            window.zoom(nil)
        }
    }

    private func refreshTabBar() {
        tabStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        tabItemObservations.removeAll()
        tabWidthConstraints.removeAll()
        // Identity lookup for this rebuild: color a tab only when it's on a
        // non-default container, so the common case stays unmarked.
        let identityMap = Dictionary(IdentityStore.shared.all().map { ($0.id, $0) },
                                     uniquingKeysWith: { a, _ in a })
        var tabItems: [TabBarItem] = []
        for (i, tab) in tabManager.tabs.enumerated() {
            let isSelected = i == tabManager.currentIndex
            let identity = identityMap[tab.identityID]
            let item = TabBarItem(
                index: i,
                title: tab.title,
                favicon: nil,
                isSelected: isSelected,
                isLoading: tab.isLoading,
                target: self,
                clickAction: #selector(tabItemClicked(_:)),
                closeAction: #selector(tabItemCloseClicked(_:)),
                secondaryAction: #selector(tabItemContextMenu(_:)),
                audioAction: #selector(tabItemAudioClicked(_:)),
                identityColor: (identity?.isDefault == false) ? identity?.color : nil
            )
            // Preserve current audio/mute state across a tab-bar rebuild.
            item.update(playingAudio: tab.isPlayingAudio, muted: tab.isMuted)
            // Drag to reorder (Chrome/Helium): the item follows the pointer
            // horizontally; on release it settles into the nearest slot. The
            // pan's movement threshold keeps plain clicks going to the click
            // recognizer untouched.
            let pan = NSPanGestureRecognizer(target: self, action: #selector(tabItemPanned(_:)))
            pan.delegate = item   // decline the drag when it starts on the close/audio button
            item.addGestureRecognizer(pan)
            item.translatesAutoresizingMaskIntoConstraints = false
            item.layer?.zPosition = isSelected ? 10 : CGFloat(tabItems.count - i)
            let widthC = item.widthAnchor.constraint(equalToConstant: TabBarItem.maxWidth)
            NSLayoutConstraint.activate([
                item.heightAnchor.constraint(equalToConstant: 30),
                widthC,
            ])
            tabWidthConstraints.append(widthC)
            tabStack.addArrangedSubview(item)
            tabItems.append(item)

            // Observe loading state to update the tab item
            let loadingObs = tab.webView.observe(\.isLoading) { [weak item] wv, _ in
                DispatchQueue.main.async { item?.update(loading: wv.isLoading) }
            }
            tabItemObservations.append(loadingObs)

            // Keep the title live for background tabs (foreground tab title is
            // driven by switchToTab; without this a cmd-clicked tab stays "New
            // Tab" until selected).
            let titleObs = tab.webView.observe(\.title) { [weak item] wv, _ in
                DispatchQueue.main.async { item?.update(title: wv.title ?? "") }
            }
            tabItemObservations.append(titleObs)

            let faviconURLObs = tab.webView.observe(\.url) { [weak item] wv, _ in
                guard let url = wv.url else { return }
                FaviconCache.shared.favicon(for: url) { [weak item] img in
                    DispatchQueue.main.async { if let img { item?.update(favicon: img) } }
                }
            }
            tabItemObservations.append(faviconURLObs)

            tab.onAudioStateChanged = { [weak item] playing, muted in
                item?.update(playingAudio: playing, muted: muted)
            }

            if let url = tab.url {
                FaviconCache.shared.favicon(for: url) { [weak item] img in
                    DispatchQueue.main.async { item?.update(title: tab.title, favicon: img) }
                }
            }
        }
        let addBtn = HoverIconButton(frame: .zero)
        addBtn.title = ""
        addBtn.target = self
        addBtn.action = #selector(newTabFromBar(_:))
        addBtn.bezelStyle = .inline
        addBtn.isBordered = false
        addBtn.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New tab")
        addBtn.contentTintColor = .secondaryLabelColor
        addBtn.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            addBtn.widthAnchor.constraint(equalToConstant: 28),
            addBtn.heightAnchor.constraint(equalToConstant: 28),
        ])
        tabStack.addArrangedSubview(addBtn)

        tabItemViews = tabItems
        updateTabWidths()
        updateURLField()
        updateIdentityAvatar()
        backBtn.isEnabled = webView.canGoBack
        forwardBtn.isEnabled = webView.canGoForward
        // Tab count may have crossed the auto-hide threshold (1↔2): re-run the
        // full chrome layout so the strip shows/hides and the toolbar reflows.
        layoutOverlays()
    }

    /// Helium/Chrome behaviour: tabs stretch to share the available width
    /// (up to a per-tab max) when there are few, and shrink toward the min as
    /// more tabs are opened.
    private func updateTabWidths() {
        let count = tabItemViews.count
        guard count > 0 else { return }
        let addBtnWidth: CGFloat = 28
        let gap: CGFloat = 4
        let rightInset: CGFloat = 8
        // gaps: one between each of the `count` tabs and the trailing "+" button.
        let totalGaps = gap * CGFloat(count)
        let avail = tabBar.bounds.width - trafficLightInset - rightInset - addBtnWidth - totalGaps
        let per = min(TabBarItem.maxWidth, max(TabBarItem.minWidth, floor(avail / CGFloat(count))))
        for c in tabWidthConstraints { c.constant = per }
    }

    /// Below this horizontal travel a pan is treated as a stationary press
    /// (a click), not a reorder — so a click that drifts a hair past the click
    /// recognizer's slop still selects the tab instead of being swallowed.
    private static let tabDragThreshold: CGFloat = 4

    @objc private func tabItemPanned(_ g: NSPanGestureRecognizer) {
        // A rebuild during the drag (e.g. a background tab opened) can leave
        // `item` orphaned with a stale index — bail rather than act on it.
        guard let item = g.view as? TabBarItem, item.index < tabManager.count else { return }
        switch g.state {
        case .changed:
            // Track the pointer horizontally only; the strip is a single row.
            let tx = g.translation(in: tabStack).x
            if abs(tx) > Self.tabDragThreshold {
                item.layer?.zPosition = 100   // lift only once it's really a drag
                item.layer?.setAffineTransform(CGAffineTransform(translationX: tx, y: 0))
            }
        case .ended, .cancelled:
            let tx = g.translation(in: tabStack).x
            item.layer?.setAffineTransform(.identity)
            if g.state == .ended, abs(tx) <= Self.tabDragThreshold {
                // Barely moved → it was a click. The click recognizer may have
                // failed on the drift, so select here instead of dropping it.
                switchToTab(tabManager.tabs[item.index])
                refreshTabBar()
                return
            }
            // One slot per full item width (incl. stack gap) the pointer moved.
            let slotW = item.bounds.width + tabStack.spacing
            let delta = slotW > 0 ? Int((tx / slotW).rounded()) : 0
            let target = max(0, min(tabManager.count - 1, item.index + delta))
            if target != item.index {
                tabManager.move(from: item.index, to: target)   // triggers refreshTabBar
            } else {
                refreshTabBar()   // settle back, clears the lifted zPosition
            }
        default:
            break
        }
    }

    @objc private func tabItemClicked(_ sender: NSClickGestureRecognizer) {
        guard let item = sender.view as? TabBarItem else { return }
        guard item.index < tabManager.count else { return }
        switchToTab(tabManager.tabs[item.index])
        refreshTabBar()
    }

    @objc private func tabItemCloseClicked(_ sender: NSButton) {
        let idx = sender.tag
        guard idx < tabManager.count else { return }
        let tab = tabManager.tabs[idx]
        dissolveSplitIfInvolved(tab)
        if tabManager.count == 1 {
            window?.close()
        } else {
            tab.webView.removeFromSuperview()   // see closeCurrentTab — avoids a leaked pane
            tabManager.close(tab)
            switchToTab(tabManager.tabs[tabManager.currentIndex])
        }
    }

    @objc private func tabItemAudioClicked(_ sender: NSButton) {
        let idx = sender.tag
        guard idx < tabManager.count else { return }
        let tab = tabManager.tabs[idx]
        tab.toggleMute()
        if idx < tabItemViews.count { tabItemViews[idx].update(muted: tab.isMuted) }
    }

    @objc private func tabItemContextMenu(_ sender: NSClickGestureRecognizer) {
        guard let item = sender.view as? TabBarItem else { return }
        guard item.index < tabManager.count else { return }
        let tab = tabManager.tabs[item.index]
        let menu = tabContextMenu(for: tab)
        let point = NSPoint(x: item.bounds.midX, y: 0)
        menu.popUp(positioning: nil, at: point, in: item)
    }

    // MARK: Identity chrome (driven by chromeless://accounts)

    /// Repaint the tab strip after an identity was renamed/recolored elsewhere.
    func reloadIdentityChrome() { refreshTabBar() }

    /// Close every tab on a deleted identity. If that empties the window, drop in
    /// a fresh default tab so it stays usable.
    func purgeIdentity(_ id: UUID) {
        let doomed = tabManager.tabs.filter { $0.identityID == id }
        guard !doomed.isEmpty else { return }   // this window has no such tabs
        // Keep the user on their current tab unless it's one of the doomed ones.
        let keep = tabManager.current.flatMap { $0.identityID == id ? nil : $0 }
        for tab in doomed {
            dissolveSplitIfInvolved(tab)
            tab.webView.removeFromSuperview()
            tabManager.close(tab)   // keeps currentIndex / mruOrder consistent
        }
        if tabManager.tabs.isEmpty {
            let tab = Tab(webView: WebViewFactory.dequeueWebView())
            tabManager.replaceAll(with: tab)
            switchToTab(tab)
            loadStartPage()
        } else {
            switchToTab(keep ?? tabManager.tabs[min(tabManager.currentIndex, tabManager.count - 1)])
        }
        refreshTabBar()
    }

    // MARK: Identity switcher

    /// Boxes a (tab, target identity) pair for the "Move to container" menu item.
    private final class MoveRequest { let tab: Tab; let identityID: UUID
        init(_ t: Tab, _ i: UUID) { tab = t; identityID = i } }

    /// Repaint the toolbar avatar to reflect the current tab's container.
    private func updateIdentityAvatar() {
        let identity = tabManager.current.flatMap { IdentityStore.shared.identity($0.identityID) }
            ?? IdentityStore.shared.defaultIdentity
        identityAvatar.image = avatarImage(for: identity, size: 26)
        identityAvatar.toolTip = "Account — \(identity.name)"
    }

    /// A round, color-filled avatar bearing the identity's emoji or initial.
    private func avatarImage(for identity: Identity, size: CGFloat) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()
        let inset: CGFloat = 2   // leave room for the button's hover ring
        let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
        identity.color.setFill()
        NSBezierPath(ovalIn: rect).fill()
        let label = identity.initial
        // Emoji glyphs render in their own color and want a larger point size than
        // a single capital letter.
        let isEmoji = label.unicodeScalars.contains { $0.properties.isEmoji && $0.value > 0x2000 }
        let font = NSFont.systemFont(ofSize: rect.height * (isEmoji ? 0.62 : 0.5), weight: .semibold)
        let str = NSAttributedString(string: label, attributes: [
            .font: font, .foregroundColor: NSColor.white])
        let sz = str.size()
        str.draw(at: NSPoint(x: rect.midX - sz.width / 2, y: rect.midY - sz.height / 2))
        img.unlockFocus()
        return img
    }

    @objc private func identityChipClicked(_ sender: NSButton) {
        identitySwitcherMenu().popUp(positioning: nil,
                                     at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    /// Menu to open a new tab in any container, or spin up a new one.
    private func identitySwitcherMenu() -> NSMenu {
        let menu = NSMenu()
        let currentID = tabManager.current?.identityID
        let header = NSMenuItem(title: "Open new tab in", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for identity in IdentityStore.shared.all() {
            let item = menu.addItem(withTitle: identity.name,
                                    action: #selector(newTabInIdentity(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = identity.id.uuidString
            item.image = identityDotImage(identity.color)
            if identity.id == currentID { item.state = .on }
        }
        // Pin the current site to the current container (auto-routing rule).
        if let cur = tabManager.current, let host = cur.url?.host,
           let identity = IdentityStore.shared.identity(cur.identityID) {
            menu.addItem(.separator())
            let pinned = IdentityStore.shared.binding(forHost: host) == cur.identityID
            let title = pinned ? "Stop always opening \(host) here"
                               : "Always open \(host) in \(identity.name)"
            let item = menu.addItem(withTitle: title,
                                    action: #selector(toggleHostBinding(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = host
        }
        menu.addItem(.separator())
        let add = menu.addItem(withTitle: "New Identity…",
                               action: #selector(promptNewIdentity(_:)), keyEquivalent: "")
        add.target = self
        let manage = menu.addItem(withTitle: "Manage Accounts…",
                                  action: #selector(openAccountsPage(_:)), keyEquivalent: "")
        manage.target = self
        return menu
    }

    @objc private func openAccountsPage(_ sender: Any?) {
        if let url = URL(string: "\(InternalScheme.scheme)://accounts") { newTab(url: url) }
        refreshTabBar()
    }

    @objc private func toggleHostBinding(_ sender: NSMenuItem) {
        guard let host = sender.representedObject as? String, let cur = tabManager.current else { return }
        if IdentityStore.shared.binding(forHost: host) == cur.identityID {
            IdentityStore.shared.setBinding(host: host, identityID: nil)
            showToast("\(host) no longer pinned")
        } else {
            IdentityStore.shared.setBinding(host: host, identityID: cur.identityID)
            let name = IdentityStore.shared.identity(cur.identityID)?.name ?? "this container"
            showToast("\(host) always opens in \(name)")
        }
    }

    /// Submenu of containers a tab can be moved into (all but its current one).
    private func moveToIdentityMenu(for tab: Tab) -> NSMenu {
        let menu = NSMenu()
        for identity in IdentityStore.shared.all() where identity.id != tab.identityID {
            let item = menu.addItem(withTitle: identity.name,
                                    action: #selector(moveTabToIdentity(_:)), keyEquivalent: "")
            item.target = self
            item.image = identityDotImage(identity.color)
            item.representedObject = MoveRequest(tab, identity.id)
        }
        return menu
    }

    private func identityDotImage(_ color: NSColor) -> NSImage {
        let s: CGFloat = 10
        let img = NSImage(size: NSSize(width: s, height: s))
        img.lockFocus()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: s - 2, height: s - 2)).fill()
        img.unlockFocus()
        return img
    }

    @objc private func newTabInIdentity(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? String, let id = UUID(uuidString: s) else { return }
        newTab(identityID: id)
        refreshTabBar()
    }

    /// Reopen a tab's page in another container. Web views are bound to one data
    /// store for life, so this creates a fresh tab in the target identity and
    /// closes the original.
    @objc private func moveTabToIdentity(_ sender: NSMenuItem) {
        guard let req = sender.representedObject as? MoveRequest else { return }
        // newTab creates the replacement in the target container and selects it.
        newTab(url: req.tab.url, identityID: req.identityID)
        guard let created = tabManager.current, created.id != req.tab.id else { refreshTabBar(); return }
        // Close the original through TabManager so currentIndex / mruOrder stay
        // consistent, then re-select the moved page (close() may shift selection).
        dissolveSplitIfInvolved(req.tab)
        req.tab.webView.removeFromSuperview()
        tabManager.close(req.tab)
        switchToTab(created)
        refreshTabBar()
    }

    @objc private func promptNewIdentity(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "New Identity"
        alert.informativeText = "A separate account container with its own cookies and logins."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "Work, Personal, Client…"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let identity = IdentityStore.shared.create(name: name)
        newTab(identityID: identity.id)
        refreshTabBar()
    }

    private func tabContextMenu(for tab: Tab) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Duplicate", action: #selector(duplicateTab(_:)), keyEquivalent: "")
            .representedObject = tab
        let copyItem = menu.addItem(withTitle: "Copy URL", action: #selector(copyTabURL(_:)), keyEquivalent: "")
        copyItem.representedObject = tab
        // Pair this tab with the active one (no-op offer on the active tab itself).
        if splitPair != nil {
            menu.addItem(withTitle: "Exit Split View", action: #selector(toggleSplitView(_:)), keyEquivalent: "")
        } else if tab.id != tabManager.current?.id {
            menu.addItem(withTitle: "Open in Split View", action: #selector(splitWithTab(_:)), keyEquivalent: "")
                .representedObject = tab
        }
        // Move this tab into another account container (only when more than the
        // default identity exists).
        if IdentityStore.shared.all().count > 1 {
            let moveItem = menu.addItem(withTitle: "Move to Container", action: nil, keyEquivalent: "")
            moveItem.submenu = moveToIdentityMenu(for: tab)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Close Tab", action: #selector(closeTabFromContext(_:)), keyEquivalent: "w")
            .representedObject = tab
        let closeOthers = menu.addItem(withTitle: "Close Other Tabs", action: #selector(closeOtherTabs(_:)), keyEquivalent: "")
        closeOthers.representedObject = tab
        return menu
    }

    @objc private func splitWithTab(_ sender: NSMenuItem) {
        guard let tab = sender.representedObject as? Tab else { return }
        enterSplitView(with: tab)
    }

    @objc private func duplicateTab(_ sender: NSMenuItem) {
        guard let tab = sender.representedObject as? Tab else { return }
        newTab(url: tab.url, identityID: tab.identityID)
    }

    @objc private func copyTabURL(_ sender: NSMenuItem) {
        guard let tab = sender.representedObject as? Tab, let url = tab.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        showToast("URL copied")
    }

    @objc private func closeTabFromContext(_ sender: NSMenuItem) {
        guard let tab = sender.representedObject as? Tab else { return }
        dissolveSplitIfInvolved(tab)
        ClosedTabStore.push(tab.url)
        if tabManager.count == 1 {
            window?.close()
            return
        }
        tab.webView.removeFromSuperview()   // see closeCurrentTab — avoids a leaked pane
        tabManager.close(tab)
        switchToTab(tabManager.tabs[tabManager.currentIndex])
    }

    @objc private func closeOtherTabs(_ sender: NSMenuItem) {
        guard let keepTab = sender.representedObject as? Tab else { return }
        if splitPair != nil { exitSplitView(); layoutOverlays() }
        let toClose = tabManager.tabs.filter { $0.id != keepTab.id }
        for tab in toClose { ClosedTabStore.push(tab.url); tab.webView.removeFromSuperview() }
        tabManager.closeAll(except: keepTab)
        switchToTab(keepTab)
    }

    @objc private func newTabFromBar(_ sender: Any?) {
        newTab()
        refreshTabBar()
    }

    @objc func reopenClosedTab(_ sender: Any?) {
        guard let url = ClosedTabStore.pop() else { return }
        newTab(url: url)
        refreshTabBar()
    }

    // Downloads panel geometry (also used by layoutOverlays for the popover
    // size). Rows are laid out top-down inside a flipped documentView.
    private static let dlRowH: CGFloat = 36
    private static let dlRowGap: CGFloat = 4
    private static let dlInset: CGFloat = 8
    private static let dlPanelW: CGFloat = 380

    private func refreshDownloads() {
        downloadsList.subviews.forEach { $0.removeFromSuperview() }
        let items = DownloadManager.shared.items.reversed()
        let contentW = Self.dlPanelW
        let rowW = contentW - Self.dlInset * 2
        let rowH = Self.dlRowH
        let labelH: CGFloat = 28
        let labelY = (rowH - labelH) / 2

        for (i, item) in items.enumerated() {
            let row = DownloadRow()
            row.frame = NSRect(x: Self.dlInset,
                               y: Self.dlInset + CGFloat(i) * (rowH + Self.dlRowGap),
                               width: rowW, height: rowH)
            row.autoresizingMask = [.width]
            let label = NSTextField(labelWithString: item.filename)
            label.font = ChromeFont.downloadTitle
            label.lineBreakMode = .byTruncatingMiddle
            row.addSubview(label)

            if item.status == .completed {
                // Completed → explicit Open + Reveal-in-Finder buttons.
                let btnSize: CGFloat = 22
                let btnGap: CGFloat = 4
                let revealX = rowW - btnSize
                let openX = revealX - btnGap - btnSize
                let btnY = (rowH - btnSize) / 2

                let openBtn = PillButton(symbol: "arrow.up.forward.app", kind: .icon) {
                    if !DownloadManager.shared.openFile(item) {
                        self.showToast("File not found")
                    }
                }
                openBtn.toolTip = "Open"
                openBtn.frame = NSRect(x: openX, y: btnY, width: btnSize, height: btnSize)
                openBtn.autoresizingMask = [.minXMargin]

                let revealBtn = PillButton(symbol: "folder", kind: .icon) {
                    if !DownloadManager.shared.revealInFinder(item) {
                        self.showToast("File not found")
                    }
                }
                revealBtn.toolTip = "Show in Finder"
                revealBtn.frame = NSRect(x: revealX, y: btnY, width: btnSize, height: btnSize)
                revealBtn.autoresizingMask = [.minXMargin]

                row.addSubview(openBtn)
                row.addSubview(revealBtn)
                label.frame = NSRect(x: 0, y: labelY, width: openX - 8, height: labelH)
                label.autoresizingMask = [.width]
            } else {
                // Running / failed → status text (failed row retries on click).
                let statusW: CGFloat = 160
                let statusLabel = NSTextField(labelWithString: Self.downloadStatusText(item))
                statusLabel.font = ChromeFont.downloadStatus
                statusLabel.textColor = item.status == .failed ? .systemRed : .secondaryLabelColor
                statusLabel.alignment = .right
                row.addSubview(statusLabel)
                label.frame = NSRect(x: 0, y: labelY, width: rowW - statusW - 10, height: labelH)
                label.autoresizingMask = [.width]
                statusLabel.frame = NSRect(x: rowW - statusW, y: labelY, width: statusW, height: labelH)
                statusLabel.autoresizingMask = [.minXMargin]

                // Determinate progress bar along the bottom while downloading.
                if item.status == .running, let f = item.fraction {
                    let barH: CGFloat = 2
                    let track = NSView(frame: NSRect(x: 0, y: 0, width: rowW, height: barH))
                    track.wantsLayer = true
                    track.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
                    track.layer?.cornerRadius = barH / 2
                    track.autoresizingMask = [.width]
                    let fill = NSView(frame: NSRect(x: 0, y: 0, width: rowW * CGFloat(f), height: barH))
                    fill.wantsLayer = true
                    fill.layer?.backgroundColor = ChromeTheme.accent.cgColor
                    fill.layer?.cornerRadius = barH / 2
                    track.addSubview(fill)
                    row.addSubview(track)
                }
                if item.status == .failed, item.resumeData != nil {
                    row.onClick = { [weak self] in
                        guard let self else { return }
                        DownloadManager.shared.resume(item, in: self.webView)
                    }
                }
            }
            downloadsList.addSubview(row)
        }
        let count = max(DownloadManager.shared.items.count, 0)
        let totalH = Self.dlInset * 2 + CGFloat(count) * rowH + CGFloat(max(0, count - 1)) * Self.dlRowGap
        downloadsList.frame = NSRect(x: 0, y: 0, width: contentW, height: totalH)
        layoutOverlays()
    }

    private static func downloadStatusText(_ item: DownloadItem) -> String {
        switch item.status {
        case .completed: return "Show in Finder"
        case .failed:    return item.resumeData != nil ? "Failed — Retry" : "Failed"
        case .running:
            let recv = ByteCountFormatter.string(fromByteCount: item.receivedBytes, countStyle: .file)
            if item.totalBytes > 0, let f = item.fraction {
                let tot = ByteCountFormatter.string(fromByteCount: item.totalBytes, countStyle: .file)
                return "\(recv) / \(tot) · \(Int(f * 100))%"
            }
            return recv   // total unknown → just bytes so far
        }
    }

    private func buildChrome(in container: NSView) {
        progressBar.wantsLayer = true
        progressBar.layer?.backgroundColor = ChromeTheme.accent.cgColor
        progressBar.alphaValue = 0
        container.addSubview(progressBar)

        toolbarBar.material = .headerView
        toolbarBar.blendingMode = .withinWindow
        toolbarBar.state = .active
        toolbarBar.wantsLayer = true
        // Same tone as the tab strip so the two rows read as one flat chrome
        // block — Helium's kColorSysHeader (#1E2020) for both rows.
        toolbarBar.layer?.backgroundColor = ChromeTheme.chromeSurface.withAlphaComponent(0.94).cgColor
        container.addSubview(toolbarBar)
        // NB: no double-click recognizer on the toolbar — it holds the editable
        // URL field, and an ancestor recognizer swallows the click that focuses
        // it. Zoom-on-double-click lives on the tab bar (the titlebar row) only.

        let navBtnConfig: (NSButton, String, Selector) -> Void = { btn, symbol, action in
            btn.wantsLayer = true
            btn.bezelStyle = .inline
            btn.isBordered = false
            btn.image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)
            btn.contentTintColor = .secondaryLabelColor
            btn.target = self
            btn.action = action
            btn.layer?.cornerRadius = 8
            btn.layer?.cornerCurve = .continuous
            self.toolbarBar.addSubview(btn)
        }
        navBtnConfig(backBtn, "chevron.left", #selector(goBackAction(_:)))
        backBtn.isEnabled = false
        navBtnConfig(forwardBtn, "chevron.right", #selector(goForwardAction(_:)))
        forwardBtn.isEnabled = false
        navBtnConfig(reloadBtn, "arrow.clockwise", #selector(reloadPage(_:)))

        navBtnConfig(downloadsButton, "tray.and.arrow.down", #selector(toggleDownloads(_:)))
        downloadsButton.toolTip = "Downloads"
        downloadsButton.isHidden = true

        // Profile avatar (Helium-style), right edge of the toolbar.
        identityAvatar.title = ""
        identityAvatar.isBordered = false
        identityAvatar.bezelStyle = .regularSquare
        identityAvatar.imagePosition = .imageOnly
        identityAvatar.setButtonType(.momentaryChange)
        identityAvatar.imageScaling = .scaleProportionallyDown
        identityAvatar.target = self
        identityAvatar.action = #selector(identityChipClicked(_:))
        identityAvatar.toolTip = "Accounts"
        toolbarBar.addSubview(identityAvatar)
        updateIdentityAvatar()

        locationBar.wantsLayer = true
        locationBar.material = .contentBackground
        locationBar.blendingMode = .withinWindow
        locationBar.state = .active
        // Helium house style: 8px rounded-rect (kHigh), not a full pill.
        locationBar.layer?.cornerRadius = 8
        locationBar.layer?.cornerCurve = .continuous
        locationBar.layer?.masksToBounds = true
        locationBar.layer?.borderWidth = 0.5
        locationBar.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        // Helium: the omnibox and the active tab share one surface tone.
        locationBar.layer?.backgroundColor = ChromeTheme.activeSurface.cgColor
        container.addSubview(locationBar)

        locationIcon.isBordered = false
        locationIcon.bezelStyle = .regularSquare
        locationIcon.imagePosition = .imageOnly
        locationIcon.title = ""
        locationIcon.focusRingType = .none
        locationIcon.setButtonType(.momentaryChange)
        locationIcon.imageScaling = .scaleProportionallyDown
        locationIcon.contentTintColor = .secondaryLabelColor
        locationIcon.target = self
        locationIcon.action = #selector(locationIconClicked(_:))
        // The button consumes its own clicks so the pill's focus gesture never
        // fires over the icon — clicking the icon opens site settings instead of
        // focusing the URL field.
        locationBar.addSubview(locationIcon)

        urlField.isBezeled = false
        urlField.isBordered = false
        urlField.drawsBackground = false
        urlField.focusRingType = .none
        urlField.font = ChromeFont.urlField
        urlField.textColor = .labelColor
        urlField.placeholderAttributedString = ChromeFont.placeholder(
            "Search Google or type a URL",
            font: ChromeFont.urlField,
            color: .secondaryLabelColor)
        urlField.usesSingleLineMode = true
        urlField.cell?.isScrollable = true
        urlField.cell?.wraps = false
        urlField.delegate = self
        urlField.lineBreakMode = .byTruncatingHead
        (urlField.cell as? NSTextFieldCell)?.truncatesLastVisibleLine = true
        locationBar.addSubview(urlField)

        // Click anywhere in the pill to focus the URL field. Native click-to-focus
        // is unreliable here (movable-by-background window + the field not filling
        // the whole pill), so drive it explicitly. The delegate lets clicks fall
        // through to the field editor once editing has begun (cursor placement).
        let pillClick = NSClickGestureRecognizer(target: self, action: #selector(locationBarClicked(_:)))
        pillClick.delegate = self
        locationBar.addGestureRecognizer(pillClick)

        tabBarSeparator.wantsLayer = true
        tabBarSeparator.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        container.addSubview(tabBarSeparator)

        tabBar.material = .headerView
        tabBar.blendingMode = .withinWindow
        tabBar.state = .active
        tabBar.wantsLayer = true
        tabBar.layer?.backgroundColor = ChromeTheme.chromeSurface.withAlphaComponent(0.94).cgColor
        container.addSubview(tabBar)
        installTitlebarDoubleClick(on: tabBar)

        tabStack.orientation = .horizontal
        tabStack.spacing = 4
        tabStack.alignment = .bottom
        tabStack.edgeInsets = NSEdgeInsets(top: 4, left: trafficLightInset, bottom: 0, right: 8)
        tabStack.translatesAutoresizingMaskIntoConstraints = false
        tabBar.addSubview(tabStack)

        hud.material = .hudWindow
        hud.blendingMode = .withinWindow
        hud.state = .active
        hud.wantsLayer = true
        hud.layer?.cornerRadius = 26
        hud.layer?.cornerCurve = .continuous
        hud.layer?.masksToBounds = true
        hud.layer?.borderWidth = 1
        hud.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        hud.isHidden = true
        hud.alphaValue = 0
        hudBacking.wantsLayer = true
        hudBacking.autoresizingMask = [.width, .height]
        hudBacking.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 0.96).cgColor
        hudBacking.layer?.cornerRadius = 26
        hudBacking.layer?.cornerCurve = .continuous
        hud.addSubview(hudBacking)
        hudField.isBezeled = false
        hudField.isBordered = false
        hudField.drawsBackground = false
        hudField.focusRingType = .none
        hudField.font = ChromeFont.hudField
        hudField.textColor = NSColor(calibratedWhite: 0.95, alpha: 1)
        hudField.placeholderAttributedString = ChromeFont.placeholder(
            "Search Google or type a URL",
            font: ChromeFont.hudField,
            color: NSColor(calibratedWhite: 0.55, alpha: 1))
        hudField.usesSingleLineMode = true
        hudField.cell?.isScrollable = true
        hudField.cell?.wraps = false
        hudField.delegate = self
        hud.addSubview(hudField)
        container.addSubview(hud)

        // Toast — top-right, styled like the password banner (Helium-style,
        // Chromeless palette): blur card, 1px hairline, leading glyph + label.
        toastView.material = .hudWindow
        toastView.blendingMode = .withinWindow
        toastView.state = .active
        toastView.wantsLayer = true
        toastView.layer?.cornerRadius = 11
        toastView.layer?.cornerCurve = .continuous
        toastView.layer?.masksToBounds = true
        toastView.layer?.borderWidth = 1
        toastView.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        toastView.isHidden = true
        toastView.alphaValue = 0
        toastIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        toastIcon.contentTintColor = ChromeTheme.accent
        toastIcon.setContentHuggingPriority(.required, for: .horizontal)
        toastLabel.font = ChromeFont.toast
        toastLabel.textColor = .labelColor
        toastLabel.lineBreakMode = .byTruncatingTail
        toastStack.orientation = .horizontal
        toastStack.spacing = 8
        toastStack.alignment = .centerY
        toastStack.translatesAutoresizingMaskIntoConstraints = false
        toastStack.addArrangedSubview(toastIcon)
        toastStack.addArrangedSubview(toastLabel)
        toastView.addSubview(toastStack)
        NSLayoutConstraint.activate([
            toastStack.leadingAnchor.constraint(equalTo: toastView.leadingAnchor, constant: 13),
            toastStack.trailingAnchor.constraint(equalTo: toastView.trailingAnchor, constant: -14),
            toastStack.centerYAnchor.constraint(equalTo: toastView.centerYAnchor),
        ])
        container.addSubview(toastView)

        autofillBanner.material = .hudWindow
        autofillBanner.blendingMode = .withinWindow
        autofillBanner.state = .active
        autofillBanner.wantsLayer = true
        autofillBanner.layer?.cornerRadius = 12
        autofillBanner.layer?.cornerCurve = .continuous
        autofillBanner.layer?.masksToBounds = true
        autofillBanner.layer?.borderWidth = 1
        autofillBanner.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        autofillBanner.isHidden = true
        autofillBanner.alphaValue = 0
        autofillIcon.image = NSImage(systemSymbolName: "key.fill", accessibilityDescription: "Password")
        autofillIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        autofillIcon.contentTintColor = .secondaryLabelColor
        autofillIcon.setContentHuggingPriority(.required, for: .horizontal)
        autofillLabel.font = ChromeFont.toast
        autofillLabel.textColor = .labelColor
        autofillLabel.lineBreakMode = .byTruncatingTail
        autofillLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        autofillStack.orientation = .horizontal
        autofillStack.spacing = 8
        autofillStack.alignment = .centerY
        autofillStack.translatesAutoresizingMaskIntoConstraints = false
        autofillStack.addArrangedSubview(autofillIcon)
        autofillStack.addArrangedSubview(autofillLabel)
        autofillBanner.addSubview(autofillStack)
        NSLayoutConstraint.activate([
            autofillStack.leadingAnchor.constraint(equalTo: autofillBanner.leadingAnchor, constant: 12),
            autofillStack.trailingAnchor.constraint(equalTo: autofillBanner.trailingAnchor, constant: -8),
            autofillStack.centerYAnchor.constraint(equalTo: autofillBanner.centerYAnchor),
        ])
        container.addSubview(autofillBanner)

        findBar.material = .hudWindow
        findBar.blendingMode = .withinWindow
        findBar.state = .active
        findBar.wantsLayer = true
        findBar.layer?.cornerRadius = 18
        findBar.layer?.cornerCurve = .continuous
        findBar.layer?.masksToBounds = true
        findBar.layer?.borderWidth = 1
        findBar.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        findBar.isHidden = true
        findBar.alphaValue = 0

        findPrevButton.title = "▲"
        findPrevButton.bezelStyle = .inline
        findPrevButton.target = self
        findPrevButton.action = #selector(findPrev(_:))
        findBar.addSubview(findPrevButton)

        findField.isBezeled = false
        findField.isBordered = false
        findField.drawsBackground = false
        findField.focusRingType = .none
        findField.font = ChromeFont.findField
        findField.textColor = .labelColor
        findField.placeholderAttributedString = ChromeFont.placeholder(
            "Find", font: ChromeFont.findField, color: .secondaryLabelColor)
        findField.usesSingleLineMode = true
        findField.cell?.isScrollable = true
        findField.cell?.wraps = false
        findField.delegate = self
        findBar.addSubview(findField)

        findStatusLabel.font = ChromeFont.findStatus
        findStatusLabel.textColor = .secondaryLabelColor
        findBar.addSubview(findStatusLabel)

        findNextButton.title = "▼"
        findNextButton.bezelStyle = .inline
        findNextButton.target = self
        findNextButton.action = #selector(findNext(_:))
        findBar.addSubview(findNextButton)

        findCloseButton.title = "×"
        findCloseButton.bezelStyle = .inline
        findCloseButton.target = self
        findCloseButton.action = #selector(hideFindBar(_:))
        findBar.addSubview(findCloseButton)

        container.addSubview(findBar)

        downloadsOverlay.material = .hudWindow
        downloadsOverlay.blendingMode = .withinWindow
        downloadsOverlay.state = .active
        downloadsOverlay.wantsLayer = true
        downloadsOverlay.layer?.cornerRadius = 18
        downloadsOverlay.layer?.cornerCurve = .continuous
        downloadsOverlay.layer?.masksToBounds = true
        downloadsOverlay.layer?.borderWidth = 1
        downloadsOverlay.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        downloadsOverlay.isHidden = true
        downloadsOverlay.alphaValue = 0

        downloadsScrollView.documentView = downloadsList
        downloadsScrollView.hasVerticalScroller = true
        downloadsScrollView.drawsBackground = false
        downloadsOverlay.addSubview(downloadsScrollView)

        container.addSubview(downloadsOverlay)

        DownloadManager.shared.onUpdate = { [weak self] in
            DispatchQueue.main.async { self?.downloadsDidUpdate() }
        }

        suggestionsView.material = .hudWindow
        suggestionsView.blendingMode = .withinWindow
        suggestionsView.state = .active
        suggestionsView.wantsLayer = true
        suggestionsView.layer?.cornerRadius = 11
        suggestionsView.layer?.cornerCurve = .continuous
        suggestionsView.layer?.masksToBounds = true
        suggestionsView.layer?.borderWidth = 1
        suggestionsView.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        suggestionsView.isHidden = true

        suggestionsBacking.wantsLayer = true
        suggestionsBacking.autoresizingMask = [.width, .height]
        suggestionsBacking.layer?.backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 0.96).cgColor
        suggestionsBacking.layer?.cornerRadius = 11
        suggestionsBacking.layer?.cornerCurve = .continuous
        suggestionsView.addSubview(suggestionsBacking)

        suggestionsView.addSubview(suggestionsStack)
        container.addSubview(suggestionsView)

        statusBubble.isHidden = true
        container.addSubview(statusBubble)
    }

    // MARK: Status bubble (hover link preview)

    func showStatusBubble(_ urlString: String) {
        // Settings ▸ General ▸ Features: link preview bubble (default on).
        guard UserDefaults.standard.object(forKey: "LinkPreviewBubble") as? Bool ?? true else { return }
        var display = prettyURL(urlString)
        if display.hasPrefix("www.") { display.removeFirst(4) }
        statusBubble.text = display
        statusBubbleHide?.cancel()
        let wasHidden = statusBubble.isHidden
        statusBubble.isHidden = false
        // Only the bubble's own frame needs updating — this fires on every <a>
        // the cursor crosses, so a full-window layoutOverlays() here was a full
        // chrome relayout per hovered link.
        layoutStatusBubble()
        if wasHidden {
            statusBubble.alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                statusBubble.animator().alphaValue = 1
            }
        } else {
            statusBubble.alphaValue = 1
        }
    }

    func hideStatusBubble() {
        guard !statusBubble.isHidden else { return }
        statusBubbleHide?.cancel()
        // Small delay so rapid mouseover/out flicker across a link doesn't thrash.
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.12
                self.statusBubble.animator().alphaValue = 0
            }, completionHandler: {
                // A show that arrived mid-fade set alpha back to 1; don't hide
                // a bubble that's now previewing a freshly-hovered link.
                if self.statusBubble.alphaValue == 0 { self.statusBubble.isHidden = true }
            })
        }
        statusBubbleHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
    }

    /// Position + size just the status bubble for its current text (bottom-left).
    private func layoutStatusBubble() {
        guard !statusBubble.isHidden, let b = window?.contentView?.bounds else { return }
        let sbW = statusBubble.fittingWidth(maxWidth: b.width * 0.5)
        let sbInset: CGFloat = 8
        statusBubble.frame = NSRect(x: sbInset, y: sbInset, width: sbW, height: 24)
        statusBubble.layoutLabel()
    }

    private func layoutOverlays() {
        guard let contentView = window?.contentView else { return }
        overlayRoot.frame = contentView.bounds
        let b = overlayRoot.bounds
        let chromeTop = chromeTopHeight

        let hideTabs = tabBarHidden
        let stripHeight = hideTabs ? 0 : tabBarHeight
        // Zen: as zenSlide goes 1→0 the whole chrome translates up by its own
        // height until it's parked just above the top edge (off-screen).
        let zenDY = zenModeEnabled ? (1 - zenSlide) * chromeTopHeight : 0
        let toolbarY = b.height - stripHeight - toolbarHeight + tabToolbarOverlap + zenDY
        toolbarBar.frame = NSRect(x: 0, y: toolbarY, width: b.width, height: toolbarHeight)

        tabBar.isHidden = hideTabs
        tabBar.frame = NSRect(x: 0, y: b.height - tabBarHeight + zenDY, width: b.width, height: tabBarHeight)
        tabStack.frame = tabBar.bounds
        updateTabWidths()
        // No hairline between tab strip and toolbar — the chrome reads as one
        // flat block (Helium: group by spacing, not divider lines).
        tabBarSeparator.isHidden = true

        // Zen: fade the traffic lights in step with the sliding chrome, and gate
        // their clicks on being (mostly) visible.
        if zenModeEnabled {
            for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
                let btn = window?.standardWindowButton(kind)
                btn?.alphaValue = zenSlide
                btn?.isEnabled = zenSlide > 0.5
            }
        }

        let navBtnSize: CGFloat = 28
        let navPad: CGFloat = 12
        let navBtnGap: CGFloat = 2
        // With the tab strip hidden the toolbar rises to the very top, where the
        // traffic lights live — inset the nav buttons past them.
        var navX = hideTabs ? trafficLightInset : navPad
        for btn in [backBtn, forwardBtn, reloadBtn] {
            btn.frame = NSRect(x: navX, y: (toolbarHeight - navBtnSize) / 2,
                               width: navBtnSize, height: navBtnSize)
            navX += navBtnSize + navBtnGap
        }

        // Right cluster: profile avatar hard against the right edge (Helium),
        // downloads button just left of it when a download exists.
        let avatarSize: CGFloat = 26
        identityAvatar.frame = NSRect(x: b.width - navPad - avatarSize,
                                      y: (toolbarHeight - avatarSize) / 2,
                                      width: avatarSize, height: avatarSize)
        identityAvatar.layer?.cornerRadius = avatarSize / 2
        var rightInset = avatarSize + 8

        let dlVisible = DownloadManager.shared.hasItems
        downloadsButton.isHidden = !dlVisible
        if dlVisible {
            downloadsButton.frame = NSRect(x: b.width - navPad - avatarSize - navBtnGap - navBtnSize,
                                           y: (toolbarHeight - navBtnSize) / 2,
                                           width: navBtnSize, height: navBtnSize)
            rightInset += navBtnSize + navBtnGap
        }
        toolbarRightInset = rightInset

        locationBar.frame = centeredLocationBarFrame(windowWidth: b.width, toolbarY: toolbarY)

        let iconSize: CGFloat = 14
        let iconPad: CGFloat = 10
        locationIcon.frame = NSRect(x: iconPad, y: (locationBar.frame.height - iconSize) / 2,
                                    width: iconSize, height: iconSize)
        // Symmetric left/right margins so centered text lands on the pill's
        // centre; fixed height, vertically centred (an editable NSTextField does
        // not vertically centre its text inside a taller frame).
        let urlX = iconPad + iconSize + 6
        let fieldH = ceil(ChromeFont.urlField.boundingRectForFont.height) + 4
        let fieldY = (locationBar.frame.height - fieldH) / 2
        urlField.frame = NSRect(x: urlX, y: fieldY,
                                width: max(0, locationBar.frame.width - urlX * 2),
                                height: fieldH)

        if let (l, r) = splitPair {
            frameWebView(l.webView)
            frameWebView(r.webView)
            let contentTop = zenModeEnabled ? 0 : chromeTop
            splitDivider.frame = splitGeometry(in: b, contentTop: contentTop).divider
            window?.invalidateCursorRects(for: splitDivider)
        } else {
            frameWebView(webView)
        }

        hudW = min(620, max(280, b.width - 48))
        let hudH: CGFloat = 52
        hud.frame = NSRect(x: (b.width - hudW) / 2, y: b.height - hudH - 84, width: hudW, height: hudH)
        hudBacking.frame = hud.bounds
        hudField.frame = NSRect(x: 20, y: (hudH - 22) / 2, width: hudW - 40, height: 22)

        toastStack.layoutSubtreeIfNeeded()
        let iconW: CGFloat = toastIcon.image == nil ? 0 : 18
        let labelW = ceil(toastLabel.attributedStringValue.size().width) + 2
        let th: CGFloat = 32
        let tw = min(b.width - 28, 13 + iconW + (iconW > 0 ? 8 : 0) + labelW + 14)
        let margin: CGFloat = 14
        // Top-right, tucked just under the chrome.
        toastView.frame = NSRect(x: b.width - tw - margin,
                                 y: b.height - chromeTop - th - margin,
                                 width: tw, height: th)

        // Zen hides the chrome, so pin the progress line to the very top edge.
        let progressY = zenModeEnabled ? b.height - 2 : b.height - chromeTop
        progressBar.frame = NSRect(x: 0, y: progressY, width: b.width * lastProgress, height: 2)

        layoutStatusBubble()

        let fbW: CGFloat = 360
        let fbH: CGFloat = 40
        let fbX = b.width - fbW - 20
        let fbY: CGFloat = 20
        findBar.frame = NSRect(x: fbX, y: fbY, width: fbW, height: fbH)

        let btnSize: CGFloat = 24
        let padding: CGFloat = 8
        var fbXPos: CGFloat = padding
        findPrevButton.frame = NSRect(x: fbXPos, y: (fbH - btnSize) / 2, width: btnSize, height: btnSize)
        fbXPos += btnSize + 4

        let fieldW = fbW - (padding * 2) - (btnSize * 4) - 12
        findField.frame = NSRect(x: fbXPos, y: (fbH - 20) / 2, width: fieldW, height: 20)
        fbXPos += fieldW + 4

        findStatusLabel.frame = NSRect(x: fbXPos, y: (fbH - 16) / 2, width: 40, height: 16)
        fbXPos += 44

        findNextButton.frame = NSRect(x: fbXPos, y: (fbH - btnSize) / 2, width: btnSize, height: btnSize)
        fbXPos += btnSize + 4

        findCloseButton.frame = NSRect(x: fbXPos, y: (fbH - btnSize) / 2, width: btnSize, height: btnSize)

        if !downloadsOverlay.isHidden {
            let dovW = Self.dlPanelW
            let count = max(1, DownloadManager.shared.items.count)
            let contentH = Self.dlInset * 2 + CGFloat(count) * Self.dlRowH
                + CGFloat(count - 1) * Self.dlRowGap
            let dovH = min(440, contentH)
            // Anchor just below the chrome, right edge aligned under the
            // downloads button, so it drops from the button rather than
            // overlapping the toolbar.
            downloadsOverlay.frame = NSRect(x: b.width - dovW - 12,
                                            y: b.height - chromeTopHeight - dovH - 6,
                                            width: dovW, height: dovH)
            downloadsScrollView.frame = downloadsOverlay.bounds
        }

        if !suggestionsView.isHidden {
            let svH = CGFloat(min(suggestionItems.count, 8)) * Self.suggestionRowHeight + 8
            let svW: CGFloat
            let svX: CGFloat
            let svY: CGFloat
            if !hud.isHidden {
                svW = hudW
                svX = hud.frame.minX
                svY = hud.frame.minY - svH - 4
            } else {
                svW = locationBar.frame.width
                svX = locationBar.frame.minX
                svY = locationBar.frame.minY - svH - 4
            }
            suggestionsView.frame = NSRect(x: svX, y: svY, width: svW, height: svH)
            suggestionsBacking.frame = suggestionsView.bounds
            suggestionsStack.frame = suggestionsView.bounds.insetBy(dx: 4, dy: 4)
            layoutSuggestionRows()
        }
    }

    private func observeWebView() {
        observations = [
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in
                self?.progressChanged(wv.estimatedProgress)
            },
            // Title changes only need the window title — each TabBarItem keeps
            // its own live title observer (see refreshTabBar), so a full strip
            // rebuild here (views + observers + favicon refetch for every tab,
            // several times per page load) was pure waste.
            webView.observe(\.title) { [weak self] wv, _ in
                let t = wv.title ?? ""
                self?.window?.title = t.isEmpty ? "Chromeless" : t
            },
            webView.observe(\.url) { [weak self] wv, _ in
                if let u = wv.url, u.scheme == "https" || u.scheme == "http" {
                    UserDefaults.standard.set(u.absoluteString, forKey: "LastURL")
                }
                DispatchQueue.main.async {
                    self?.updateURLField()
                    self?.backBtn.isEnabled = wv.canGoBack
                    self?.forwardBtn.isEnabled = wv.canGoForward
                }
            },
        ]
    }

    private func progressChanged(_ progress: Double) {
        lastProgress = CGFloat(progress)
        if let width = window?.contentView?.bounds.width {
            progressBar.frame.size.width = width * lastProgress
        }
        if progress >= 1.0 {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.35
                progressBar.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                self?.lastProgress = 0
                self?.layoutOverlays()
            })
        } else {
            progressBar.alphaValue = 1
        }
    }

    // MARK: Navigation

    func navigate(to url: URL) {
        onStartPage = false
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
        updateURLField()
    }

    func loadStartPage() {
        onStartPage = true
        webView.loadHTMLString(startPageHTML, baseURL: nil)
        updateURLField()
    }

    private func escapeToStart() -> Bool {
        if onStartPage { return false }
        loadStartPage()
        return true
    }

    // MARK: HUD (the ⌘L address bar)

    func showHUD() {
        if let u = webView.url, !onStartPage, u.absoluteString != "about:blank" {
            hudField.stringValue = u.absoluteString
        } else {
            hudField.stringValue = ""
        }
        hud.isHidden = false
        layoutOverlays()
        hud.alphaValue = 0.9
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            hud.animator().alphaValue = 1
        }
        window?.makeFirstResponder(hudField)
        hudField.selectText(nil)
    }

    func hideHUD() {
        dismissSuggestions()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            self.hud.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.hud.isHidden = true
            self.window?.makeFirstResponder(self.webView)
        })
    }

    @objc private func locationBarClicked(_ sender: NSClickGestureRecognizer) {
        focusURLField()
    }

    // Only claim the click to focus when the field is not already being edited;
    // once the field editor is active, decline so clicks reach it for cursor
    // placement and text selection.
    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer,
                           shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        if gestureRecognizer.view === locationBar {
            // Clicks on the leading icon belong to it (site settings), not to the
            // pill's focus gesture.
            let p = event.locationInWindow
            let iconInWindow = locationIcon.convert(locationIcon.bounds, to: nil)
            if iconInWindow.contains(p) { return false }
            return urlField.currentEditor() == nil
        }
        return true
    }

    func focusURLField() {
        // In zen the toolbar may be slid off-screen; snap it fully open first so
        // the field has non-zero height to receive focus (Helium does the same).
        if zenModeEnabled && zenSlide < 1 {
            zenAnimTimer?.invalidate(); zenAnimTimer = nil
            zenRevealed = true
            zenSlide = 1
            layoutOverlays()
        }
        updateURLField()
        // Editing always operates on the full URL, left-aligned — even when the
        // idle bar shows only the host (minimal mode).
        if minimalAddressBar, let u = webView.url, !onStartPage, u.absoluteString != "about:blank" {
            urlField.stringValue = u.absoluteString
        }
        urlField.alignment = .natural
        // While editing, the leading glyph is a search magnifier (image 2), not
        // the site-settings "tune" glyph — you're about to search or type a URL.
        locationIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Search")
        locationIcon.contentTintColor = .secondaryLabelColor
        locationBar.layer?.borderColor = ChromeTheme.accent.withAlphaComponent(0.45).cgColor
        locationBar.layer?.borderWidth = 1
        // Set the flag up front rather than waiting for the (unreliable)
        // controlTextDidBeginEditing notification to arm the steal guard.
        (window as? BrowserWindow)?.isEditingURLField = true
        window?.makeFirstResponder(urlField)
        urlField.selectText(nil)
    }

    private func commitHUD() {
        let text = hudField.stringValue
        hideHUD()
        if let url = smartURL(text) { navigate(to: url) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if control == findField {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                hideFindBar(nil)
                return true
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                findNext(nil)
                return true
            }
            return false
        }
        if control == urlField {
            if commandSelector == #selector(NSResponder.moveUp(_:)) {
                if selectedSuggestionIndex > 0 { selectedSuggestionIndex -= 1; highlightSuggestion() }
                return true
            }
            if commandSelector == #selector(NSResponder.moveDown(_:)) {
                if selectedSuggestionIndex < suggestionItems.count - 1 { selectedSuggestionIndex += 1; highlightSuggestion() }
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                dismissSuggestions()
                let win = window as? BrowserWindow
                win?.isEditingURLField = false
                win?.forceAllowFocusChange = true
                window?.makeFirstResponder(webView)
                updateURLField()
                return true
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if selectedSuggestionIndex >= 0 && selectedSuggestionIndex < suggestionItems.count {
                    let item = suggestionItems[selectedSuggestionIndex]
                    dismissSuggestions()
                    let win = window as? BrowserWindow
                    win?.isEditingURLField = false
                    win?.forceAllowFocusChange = true
                    window?.makeFirstResponder(webView)
                    if let url = URL(string: item.url) { navigate(to: url) }
                } else {
                    commitURLField()
                }
                return true
            }
            return false
        }
        if control == hudField {
            if commandSelector == #selector(NSResponder.moveUp(_:)) {
                if selectedSuggestionIndex > 0 { selectedSuggestionIndex -= 1; highlightSuggestion() }
                return true
            }
            if commandSelector == #selector(NSResponder.moveDown(_:)) {
                if selectedSuggestionIndex < suggestionItems.count - 1 { selectedSuggestionIndex += 1; highlightSuggestion() }
                return true
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if selectedSuggestionIndex >= 0 && selectedSuggestionIndex < suggestionItems.count {
                    let item = suggestionItems[selectedSuggestionIndex]
                    hideHUD()
                    if let url = URL(string: item.url) { navigate(to: url) }
                } else {
                    commitHUD()
                }
                return true
            }
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { hideHUD(); suggestionsView.isHidden = true; return true }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { commitHUD(); return true }
        return false
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        if obj.object as? NSTextField == urlField {
            (window as? BrowserWindow)?.isEditingURLField = true
            urlField.alignment = .natural
            locationIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Search")
            locationIcon.contentTintColor = .secondaryLabelColor
            locationBar.layer?.borderColor = ChromeTheme.accent.withAlphaComponent(0.45).cgColor
            locationBar.layer?.borderWidth = 1
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if obj.object as? NSTextField == urlField {
            (window as? BrowserWindow)?.isEditingURLField = false
            locationBar.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
            locationBar.layer?.borderWidth = 0.5
            // Revert the field to its idle display (full URL, or host in minimal
            // mode) — discards any uncommitted text, standard browser behaviour.
            updateURLField()
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        if obj.object as? NSTextField == findField {
            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(runFind), object: nil)
            perform(#selector(runFind), with: nil, afterDelay: 0.15)
        } else if obj.object as? NSTextField == hudField {
            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(updateSuggestions), object: nil)
            perform(#selector(updateSuggestions), with: nil, afterDelay: 0.15)
        } else if obj.object as? NSTextField == urlField {
            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(updateURLSuggestions), object: nil)
            perform(#selector(updateURLSuggestions), with: nil, afterDelay: 0.15)
        }
    }

    /// `@work github.com` opens github.com in the Work container; `@work` alone
    /// opens a fresh Work tab. Matched case-insensitively against identity names
    /// (full, spaces-stripped, or first word). nil when nothing matches, so a
    /// stray "@…" just falls through to a normal search.
    private func parseIdentityBang(_ text: String) -> (identity: Identity, rest: String)? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("@"), t.count > 1 else { return nil }
        let parts = t.dropFirst().split(separator: " ", maxSplits: 1)
        guard let token = parts.first.map({ $0.lowercased() }) else { return nil }
        let rest = parts.count > 1 ? String(parts[1]) : ""
        let match = IdentityStore.shared.all().first { i in
            let n = i.name.lowercased()
            return n == token
                || n.replacingOccurrences(of: " ", with: "") == token
                || n.split(separator: " ").first.map(String.init) == token
        }
        return match.map { ($0, rest) }
    }

    private func commitURLField() {
        let text = urlField.stringValue
        dismissSuggestions()
        let win = window as? BrowserWindow
        win?.isEditingURLField = false
        win?.forceAllowFocusChange = true   // our own commit — not a page focus-steal
        window?.makeFirstResponder(webView)
        // @identity bang: open in the named container instead of the current tab.
        if let (identity, rest) = parseIdentityBang(text) {
            newTab(url: rest.isEmpty ? nil : smartURL(rest), identityID: identity.id)
            refreshTabBar()
            return
        }
        if let url = smartURL(text) {
            navigate(to: url)
        } else if onStartPage && text.trimmingCharacters(in: .whitespaces).isEmpty {
            updateURLField()
        }
    }

    @objc private func updateURLSuggestions() {
        loadSuggestions(query: urlField.stringValue.trimmingCharacters(in: .whitespaces), isHUD: false)
    }

    /// Fully tear down the suggestions dropdown: hide it, cancel any pending
    /// debounced rebuild, and bump the query token so an in-flight async
    /// engine-suggest reply can't re-present it after the field is committed.
    private func dismissSuggestions() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(updateURLSuggestions), object: nil)
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(updateSuggestions), object: nil)
        suggestionQueryToken += 1
        suggestionsView.isHidden = true
        selectedSuggestionIndex = -1
    }

    /// Builds the suggestion list for `query`: local history first, then — when
    /// engine suggestions are enabled — phrases fetched from the default search
    /// engine's suggest endpoint, merged in on a later async pass.
    private func loadSuggestions(query: String, isHUD: Bool) {
        guard query.count >= 2 else {
            suggestionsView.isHidden = true
            return
        }
        suggestionQueryToken += 1
        let token = suggestionQueryToken

        // `!bang` matches lead the list (spark icon + "Ask %@" for AI bangs).
        let bangs = Bangs.suggestions(for: query).map { s in
            Suggestion(url: s.url.absoluteString,
                       title: s.bang.name,
                       subtitle: (s.bang.category == .ai ? "Ask " : "Search ") + s.bang.name,
                       isSearch: true)
        }
        let history = HistoryStore.shared.search(query: query).map {
            Suggestion(url: $0.url, title: $0.title, subtitle: $0.url, isSearch: false)
        }
        presentSuggestions(bangs + history, query: query, isHUD: isHUD) // show immediately

        // An active bang owns the omnibox — skip remote engine suggestions.
        guard bangs.isEmpty else { return }
        guard SearchEngine.suggestionsEnabled else { return }
        SearchSuggest.fetch(query) { [weak self] phrases in
            guard let self, token == self.suggestionQueryToken else { return } // stale reply
            let engine = SearchEngine.current
            let seen = Set(history.map { $0.title.lowercased() })
            let searchItems = phrases.prefix(6).compactMap { phrase -> Suggestion? in
                guard !seen.contains(phrase.lowercased()), let url = engine.searchURL(for: phrase) else { return nil }
                return Suggestion(url: url.absoluteString, title: phrase, subtitle: "\(engine.label) Search", isSearch: true)
            }
            guard !searchItems.isEmpty else { return }
            self.presentSuggestions(history + searchItems, query: query, isHUD: isHUD)
        }
    }

    private static let suggestionRowHeight: CGFloat = 30

    /// Renders `list` into the suggestion popover, Helium-style: one line per
    /// row — a leading type icon, the title, then a dimmer trailing detail
    /// (pretty URL or "<Engine> Search"), with the typed query bolded. `query`
    /// drives the bold match; geometry is applied in `layoutSuggestionRows()`.
    private func presentSuggestions(_ list: [Suggestion], query: String, isHUD: Bool) {
        suggestionItems = list
        guard !list.isEmpty else {
            suggestionsView.isHidden = true
            return
        }
        suggestionsStack.subviews.forEach { $0.removeFromSuperview() }
        selectedSuggestionIndex = -1
        let action = isHUD ? #selector(suggestionRowClicked(_:)) : #selector(urlSuggestionRowClicked(_:))
        for (i, item) in list.prefix(8).enumerated() {
            let row = SuggestionRow(index: i, target: self, action: action)
            row.layer?.cornerRadius = 6
            row.layer?.cornerCurve = .continuous

            let symbol = item.isSearch ? "magnifyingglass" : "globe"
            let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
            icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: isHUD ? 13 : 12, weight: .regular)
            icon.contentTintColor = .secondaryLabelColor
            icon.tag = 3

            let label = NSTextField(labelWithAttributedString: suggestionText(item, query: query, isHUD: isHUD))
            label.tag = 1
            label.lineBreakMode = .byTruncatingTail
            label.cell?.usesSingleLineMode = true

            row.addSubview(icon)
            row.addSubview(label)
            suggestionsStack.addSubview(row)
        }
        suggestionsView.isHidden = false
        layoutOverlays()
    }

    /// `title  –  detail` with the typed query bolded wherever it appears. The
    /// detail is dimmed; page URLs get the accent tint, search phrases stay grey.
    private func suggestionText(_ s: Suggestion, query: String, isHUD: Bool) -> NSAttributedString {
        let size: CGFloat = isHUD ? 13 : 12
        let font = NSFont.systemFont(ofSize: size)
        let bold = NSFont.systemFont(ofSize: size, weight: .semibold)
        let out = NSMutableAttributedString()

        let title = s.title.isEmpty ? prettyURL(s.url) : s.title
        out.append(NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: NSColor.labelColor]))

        let detail = s.isSearch ? s.subtitle : prettyURL(s.subtitle)
        if !detail.isEmpty {
            out.append(NSAttributedString(string: "  –  ", attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]))
            out.append(NSAttributedString(string: detail, attributes: [
                .font: font,
                .foregroundColor: s.isSearch ? NSColor.secondaryLabelColor : ChromeTheme.accent,
            ]))
        }

        // Bold every case-insensitive occurrence of the typed query.
        if query.count >= 1 {
            let full = out.string as NSString
            var scan = NSRange(location: 0, length: full.length)
            while scan.location < full.length {
                let hit = full.range(of: query, options: .caseInsensitive, range: scan)
                if hit.location == NSNotFound { break }
                out.addAttribute(.font, value: bold, range: hit)
                let next = hit.location + max(hit.length, 1)
                scan = NSRange(location: next, length: full.length - next)
            }
        }
        return out
    }

    /// Strips scheme and trailing slash for a compact, Helium-style URL.
    private func prettyURL(_ raw: String) -> String {
        var s = raw
        for p in ["https://", "http://"] where s.hasPrefix(p) { s.removeFirst(p.count) }
        if s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// Positions the suggestion rows top-to-bottom to fill `suggestionsStack`.
    /// Called from `layoutOverlays()` so rows track the popover's real width.
    private func layoutSuggestionRows() {
        let rowH = Self.suggestionRowHeight
        let contentW = suggestionsStack.bounds.width
        let stackH = suggestionsStack.bounds.height
        let iconSize: CGFloat = 16
        let leftPad: CGFloat = 11
        let textX = leftPad + iconSize + 10
        for (i, row) in suggestionsStack.subviews.enumerated() {
            // AppKit is y-up; row 0 sits at the top of the popover.
            row.frame = NSRect(x: 0, y: stackH - CGFloat(i + 1) * rowH, width: contentW, height: rowH)
            (row.viewWithTag(3))?.frame = NSRect(x: leftPad, y: (rowH - iconSize) / 2, width: iconSize, height: iconSize)
            (row.viewWithTag(1))?.frame = NSRect(x: textX, y: (rowH - 17) / 2, width: contentW - textX - 10, height: 17)
        }
    }

    @objc private func urlSuggestionRowClicked(_ sender: SuggestionRow) {
        guard sender.index < suggestionItems.count else { return }
        let item = suggestionItems[sender.index]
        suggestionsView.isHidden = true
        window?.makeFirstResponder(webView)
        if let url = URL(string: item.url) { navigate(to: url) }
    }

    @objc private func updateSuggestions() {
        loadSuggestions(query: hudField.stringValue.trimmingCharacters(in: .whitespaces), isHUD: true)
    }

    @objc private func suggestionRowClicked(_ sender: SuggestionRow) {
        guard sender.index < suggestionItems.count else { return }
        let item = suggestionItems[sender.index]
        hideHUD()
        if let url = URL(string: item.url) { navigate(to: url) }
    }

    private func highlightSuggestion() {
        for (i, subview) in suggestionsStack.subviews.enumerated() {
            subview.layer?.backgroundColor = (i == selectedSuggestionIndex)
                ? ChromeTheme.accent.withAlphaComponent(0.2).cgColor
                : NSColor.clear.cgColor
        }
    }

    // MARK: Autofill prompts

    private struct BannerAction { let title: String; let primary: Bool; let handler: () -> Void }

    func promptSavePassword(host: String, username: String, password: String) {
        let detail = username.isEmpty ? host : "\(username) · \(host)"
        showAutofillBanner(title: "Save password?", detail: detail, actions: [
            BannerAction(title: "Save", primary: true) { [weak self] in
                Vault.save(host: host, username: username, password: password)
                self?.showToast("Password saved")
            },
        ])
    }

    func promptFill(host: String, matches: [Vault.Credential], webView: WKWebView, frame: WKFrameInfo) {
        if matches.count == 1 {
            let m = matches[0]
            showAutofillBanner(title: "Sign in as", detail: m.username.isEmpty ? host : m.username,
                               actions: [BannerAction(title: "Fill", primary: true) {
                                   Autofill.authenticateAndFill(m, into: webView, frame: frame)
                               }])
        } else {
            // One (secondary) button per account, capped so the pill stays compact.
            let actions = matches.prefix(3).map { m in
                BannerAction(title: m.username.isEmpty ? host : m.username, primary: false) {
                    Autofill.authenticateAndFill(m, into: webView, frame: frame)
                }
            }
            showAutofillBanner(title: "Sign in", detail: nil, actions: Array(actions))
        }
    }

    /// Shows a transient, compact HUD pill: key icon, title + detail, styled
    /// action buttons, and an × dismiss. Auto-hides after 12s.
    private func showAutofillBanner(title: String, detail: String?, actions: [BannerAction]) {
        // Compose the label: bright title, dimmer detail on the same line.
        let text = NSMutableAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ])
        if let detail {
            text.append(NSAttributedString(string: "  " + detail, attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]))
        }
        autofillLabel.attributedStringValue = text

        // Rebuild buttons, keeping the icon + label at the front of the stack.
        for v in autofillStack.arrangedSubviews where v !== autofillLabel && v !== autofillIcon {
            autofillStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        for action in actions {
            let btn = PillButton(title: action.title, kind: action.primary ? .primary : .secondary) { [weak self] in
                self?.hideAutofillBanner()
                action.handler()
            }
            autofillStack.addArrangedSubview(btn)
        }
        let close = PillButton(symbol: "xmark", kind: .icon) { [weak self] in self?.hideAutofillBanner() }
        autofillStack.addArrangedSubview(close)

        autofillHide?.cancel()
        autofillBanner.isHidden = false
        positionAutofillBanner()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            autofillBanner.animator().alphaValue = 1
        }
        let work = DispatchWorkItem { [weak self] in self?.hideAutofillBanner() }
        autofillHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: work)
    }

    private func hideAutofillBanner() {
        autofillHide?.cancel()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            autofillBanner.animator().alphaValue = 0
        }, completionHandler: { [weak self] in self?.autofillBanner.isHidden = true })
    }

    private func positionAutofillBanner() {
        guard let container = autofillBanner.superview else { return }
        autofillStack.layoutSubtreeIfNeeded()
        // Sum the arranged widths ourselves — NSStackView.fittingSize squeezes the
        // low-compression label to ~0, which would collapse the pill.
        let spacing: CGFloat = 8
        var content: CGFloat = 0
        for (i, v) in autofillStack.arrangedSubviews.enumerated() {
            let vw = (v === autofillLabel)
                ? ceil(autofillLabel.attributedStringValue.size().width) + 2
                : v.intrinsicContentSize.width
            content += vw + (i > 0 ? spacing : 0)
        }
        let w = min(container.bounds.width - 40, content + 12 + 8)  // leading + trailing insets
        let h: CGFloat = 38
        autofillBanner.frame = NSRect(x: (container.bounds.width - w) / 2,
                                      y: container.bounds.height - chromeTopHeight - h - 10,
                                      width: w, height: h)
    }

    // MARK: Toast

    /// A passive/background confirmation toast, gated by the accessibility
    /// setting "Background action confirmation toasts" (default on).
    func confirmToast(_ text: String, symbol: String) {
        guard UserDefaults.standard.object(forKey: "ConfirmationToasts") as? Bool ?? true else { return }
        showToast(text, symbol: symbol)
    }

    func showToast(_ text: String, symbol: String = "info.circle.fill") {
        toastIcon.image = symbol.isEmpty ? nil
            : NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        toastIcon.isHidden = toastIcon.image == nil
        toastLabel.stringValue = text
        layoutOverlays()
        let final = toastView.frame
        toastHide?.cancel()
        toastView.isHidden = false
        // Scale + fade "pop" entrance (Helium), anchored in place at top-right.
        toastView.setFrameOrigin(final.origin)
        toastView.alphaValue = 0
        let pop = CABasicAnimation(keyPath: "transform.scale")
        pop.fromValue = 0.9
        pop.toValue = 1.0
        pop.duration = 0.22
        pop.timingFunction = CAMediaTimingFunction(name: .easeOut)
        toastView.layer?.add(pop, forKey: "pop")
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            toastView.animator().alphaValue = 1
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.28
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                self.toastView.animator().alphaValue = 0
            }, completionHandler: { self.toastView.isHidden = true })
        }
        toastHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
    }

    // MARK: Snapshots

    private func writePNG(from image: NSImage, to path: String) -> (Int, Int)? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
        else { return nil }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            return (cg.width, cg.height)
        } catch {
            return nil
        }
    }

    private func runSnapJob(_ job: SnapJob) {
        DispatchQueue.main.asyncAfter(deadline: .now() + job.wait) { [weak self] in
            guard let self else { exit(3) }
            self.webView.takeSnapshot(with: nil) { image, error in
                guard let image, let dims = self.writePNG(from: image, to: job.path) else {
                    fputs("chromeless: snapshot failed: \(error?.localizedDescription ?? "could not write PNG")\n", stderr)
                    exit(3)
                }
                print("saved \(job.path) (\(dims.0)x\(dims.1) px)")
                exit(0)
            }
        }
    }

    // MARK: Menu actions

    @objc func openLocation(_ sender: Any?) { focusURLField() }

    // MARK: Site settings

    @objc func locationIconClicked(_ sender: Any?) {
        // On the start page / blank there is no site to configure — fall back to
        // focusing the URL field so the icon still feels like part of the pill.
        guard let origin = SitePermissionStore.origin(for: webView.url), !onStartPage else {
            focusURLField()
            return
        }
        if let existing = siteSettingsPopover, existing.isShown {
            existing.close()
            siteSettingsPopover = nil
            return
        }
        showSiteSettings(origin: origin)
    }

    private func showSiteSettings(origin: String) {
        let host = URL(string: origin)?.host ?? origin
        let isSecure = origin.hasPrefix("https://")

        // Fixed geometry so every row's controls line up in a clean column.
        let rowWidth: CGFloat = 272
        let iconColumn: CGFloat = 22
        let controlWidth: CGFloat = 92

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 6
        content.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        content.translatesAutoresizingMaskIntoConstraints = false

        // Header: host + connection security.
        let hostLabel = NSTextField(labelWithString: host)
        hostLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        hostLabel.lineBreakMode = .byTruncatingTail
        hostLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        content.addArrangedSubview(hostLabel)

        let connRow = NSStackView()
        connRow.spacing = 4
        connRow.alignment = .centerY
        let connIcon = NSImageView()
        connIcon.image = NSImage(systemSymbolName: isSecure ? "lock.fill" : "exclamationmark.triangle.fill",
                                 accessibilityDescription: nil)
        connIcon.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        connIcon.contentTintColor = isSecure ? .systemGreen : .systemOrange
        let connLabel = NSTextField(labelWithString: isSecure ? "Connection is secure" : "Connection is not secure")
        connLabel.font = .systemFont(ofSize: 11)
        connLabel.textColor = .secondaryLabelColor
        connRow.addArrangedSubview(connIcon)
        connRow.addArrangedSubview(connLabel)
        content.addArrangedSubview(connRow)

        // Section label for the permission list.
        let permsHeader = NSTextField(labelWithString: "PERMISSIONS")
        permsHeader.font = .systemFont(ofSize: 10, weight: .semibold)
        permsHeader.textColor = .tertiaryLabelColor
        content.setCustomSpacing(14, after: connRow)
        content.addArrangedSubview(permsHeader)
        content.setCustomSpacing(6, after: permsHeader)

        func makeIcon(_ symbol: String) -> NSImageView {
            let v = NSImageView()
            v.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            v.symbolConfiguration = .init(pointSize: 13, weight: .regular)
            v.contentTintColor = .secondaryLabelColor
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalToConstant: iconColumn).isActive = true
            return v
        }
        func makeRow(_ views: [NSView]) -> NSStackView {
            let row = NSStackView(views: views)
            row.spacing = 8
            row.alignment = .centerY
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalToConstant: rowWidth).isActive = true
            row.heightAnchor.constraint(equalToConstant: 26).isActive = true
            return row
        }

        // Camera + microphone: fully in-app per-site control.
        for perm in SitePermission.allCases {
            let label = NSTextField(labelWithString: perm.label)
            label.font = .systemFont(ofSize: 12.5)
            let pop = NSPopUpButton()
            pop.addItems(withTitles: ["Ask", "Allow", "Block"])
            switch SitePermissionStore.shared.decision(origin, perm) {
            case .ask: pop.selectItem(at: 0)
            case .allow: pop.selectItem(at: 1)
            case .deny: pop.selectItem(at: 2)
            }
            pop.tag = perm == .camera ? 0 : 1
            pop.target = self
            pop.action = #selector(sitePermissionChanged(_:))
            pop.translatesAutoresizingMaskIntoConstraints = false
            pop.widthAnchor.constraint(equalToConstant: controlWidth).isActive = true
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            content.addArrangedSubview(makeRow([makeIcon(perm.symbol), label, spacer, pop]))
        }

        // Location: macOS-managed. Reflect the system status; deep-link out.
        let locLabel = NSTextField(labelWithString: "Location")
        locLabel.font = .systemFont(ofSize: 12.5)
        let locStatus = NSButton(title: LocationBroker.shared.statusText, target: self,
                                 action: #selector(openLocationSystemSettings(_:)))
        locStatus.isBordered = false
        locStatus.bezelStyle = .inline
        locStatus.contentTintColor = ChromeTheme.accent
        locStatus.font = .systemFont(ofSize: 11.5)
        locStatus.setContentHuggingPriority(.required, for: .horizontal)
        let locSpacer = NSView()
        locSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        content.addArrangedSubview(makeRow([makeIcon("location.fill"), locLabel, locSpacer, locStatus]))

        let hint = NSTextField(wrappingLabelWithString: "Location is granted by macOS. Open System Settings ▸ Privacy & Security to change it.")
        hint.font = .systemFont(ofSize: 10.5)
        hint.textColor = .tertiaryLabelColor
        hint.preferredMaxLayoutWidth = rowWidth
        content.setCustomSpacing(8, after: content.arrangedSubviews.last!)
        content.addArrangedSubview(hint)

        let vc = NSViewController()
        let host2 = NSView()
        host2.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: host2.topAnchor),
            content.leadingAnchor.constraint(equalTo: host2.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: host2.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: host2.bottomAnchor),
        ])
        vc.view = host2

        let popover = NSPopover()
        popover.contentViewController = vc
        popover.behavior = .transient
        popover.show(relativeTo: locationIcon.bounds, of: locationIcon, preferredEdge: .maxY)
        siteSettingsPopover = popover
        siteSettingsOrigin = origin
    }

    @objc private func sitePermissionChanged(_ sender: NSPopUpButton) {
        guard let origin = siteSettingsOrigin else { return }
        let perm: SitePermission = sender.tag == 0 ? .camera : .microphone
        let decision: PermissionDecision
        switch sender.indexOfSelectedItem {
        case 1: decision = .allow
        case 2: decision = .deny
        default: decision = .ask
        }
        SitePermissionStore.shared.set(origin, perm, decision)
    }

    @objc private func openLocationSystemSettings(_ sender: Any?) {
        LocationBroker.shared.openSystemSettings()
    }

    @objc func reloadPage(_ sender: Any?) {
        if onStartPage { loadStartPage() } else { webView.reload() }
    }

    @objc func hardReloadPage(_ sender: Any?) {
        if onStartPage { loadStartPage() } else { webView.reloadFromOrigin() }
    }

    @objc func goBackAction(_ sender: Any?) { webView.goBack(); updateURLField() }
    @objc func goForwardAction(_ sender: Any?) { webView.goForward(); updateURLField() }

    @objc func zoomInPage(_ sender: Any?) { setPageZoom(min(webView.pageZoom * 1.1, 5.0)) }
    @objc func zoomOutPage(_ sender: Any?) { setPageZoom(max(webView.pageZoom / 1.1, 0.25)) }
    @objc func resetZoom(_ sender: Any?) { setPageZoom(1.0) }

    // PiP is native on macOS WebKit (the media-controls button + JS API work with
    // no configuration). This just gives it a menu/shortcut: toggle PiP on the
    // largest playing video without hunting for the on-hover control.
    @objc func togglePictureInPicture(_ sender: Any?) {
        // Sites like YouTube set video.disablePictureInPicture, which greys out
        // the native PiP control. Clear it and drop the attribute before asking so
        // the standard PiP API still fires. Prefer a playing video; fall back to
        // the largest ready one.
        let js = """
        (function () {
          if (document.pictureInPictureElement) { document.exitPictureInPicture(); return 'exit'; }
          if (!document.pictureInPictureEnabled) return 'unsupported';
          var vids = Array.prototype.slice.call(document.querySelectorAll('video'))
            .filter(function (v) { return v.readyState > 0; });
          if (!vids.length) return 'none';
          vids.sort(function (a, b) { return (b.videoWidth * b.videoHeight) - (a.videoWidth * a.videoHeight); });
          var v = vids.filter(function (x) { return !x.paused; })[0] || vids[0];
          try { v.disablePictureInPicture = false; v.removeAttribute('disablepictureinpicture'); } catch (e) {}
          if (v.requestPictureInPicture) { v.requestPictureInPicture().catch(function () {}); return 'ok'; }
          return 'unsupported';
        })();
        """
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let s = result as? String else { return }
            if s == "none" {
                self?.showToast("No video to put in Picture in Picture")
            } else if s == "unsupported" {
                self?.showToast("This video doesn’t support Picture in Picture")
            }
        }
    }

    private func setPageZoom(_ z: CGFloat) {
        webView.pageZoom = z
        if let host = webView.url?.host { ZoomStore.set(z, for: host) }
    }

    @objc func saveSnapshot(_ sender: Any?) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let name = "chromeless \(formatter.string(from: Date())).png"
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let path = desktop.appendingPathComponent(name).path
        webView.takeSnapshot(with: nil) { [weak self] image, _ in
            guard let self else { return }
            if let image, self.writePNG(from: image, to: path) != nil {
                self.showToast("Saved “\(name)” to Desktop")
            } else {
                self.showToast("Snapshot failed")
            }
        }
    }

    @objc func copyPageURL(_ sender: Any?) {
        guard let u = webView.url, u.absoluteString != "about:blank" else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(u.absoluteString, forType: .string)
        showToast("URL copied")
    }

    @objc func togglePin(_ sender: Any?) {
        guard let window else { return }
        let pinned = window.level == .floating
        window.level = pinned ? .normal : .floating
        showToast(pinned ? "Unpinned" : "Pinned on top")
    }

    @objc func showHelpPage(_ sender: Any?) { loadStartPage() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(goBackAction(_:)): return webView.canGoBack
        case #selector(goForwardAction(_:)): return webView.canGoForward
        case #selector(copyPageURL(_:)):
            return webView.url != nil && webView.url?.absoluteString != "about:blank"
        case #selector(togglePin(_:)):
            menuItem.state = window?.level == .floating ? .on : .off
            return true
        case #selector(toggleSplitView(_:)):
            menuItem.state = splitPair != nil ? .on : .off
            return splitPair != nil || tabManager.count > 1
        default: return true
        }
    }

    // MARK: NSWindowDelegate

    func windowDidEnterFullScreen(_ notification: Notification) { setTrafficLights(visible: true) }
    func windowDidExitFullScreen(_ notification: Notification) { setTrafficLights(visible: false) }

    func windowWillClose(_ notification: Notification) {
        if let monitor = mouseMonitor { NSEvent.removeMonitor(monitor) }
        mouseMonitor = nil
        observations.removeAll()
        onClose?()
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        let u = webView.url?.absoluteString
        if u != nil && u != "about:blank" { onStartPage = false }
        if !findBar.isHidden { hideFindBar(nil) }
        // Apply the per-site zoom the moment the new document commits, before it
        // paints, so there's no visible reflow from 100% → stored level.
        if let host = webView.url?.host {
            let z = ZoomStore.zoom(for: host)
            if webView.pageZoom != z { webView.pageZoom = z }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let url = webView.url, !onStartPage,
           let scheme = url.scheme, scheme == "http" || scheme == "https" {
            HistoryStore.shared.recordVisit(url: url, title: webView.title ?? "")
        }

        if let job = snapJob {
            snapJob = nil
            runSnapJob(job)
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleLoadError(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleLoadError(error)
    }

    private func handleLoadError(_ error: Error) {
        let e = error as NSError
        // Ignore cancelled loads and "frame load interrupted" (downloads, redirects).
        if e.code == NSURLErrorCancelled || e.code == 102 { return }
        if launchOptions.snap != nil {
            fputs("chromeless: load failed: \(e.localizedDescription)\n", stderr)
            exit(1)
        }
        showToast("Couldn’t load — \(e.localizedDescription)")
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Deny top-level data:/javascript: documents — they render attacker HTML
        // under an opaque address bar (phishing surface). Still fine as
        // subresources/subframes, which don't set isMainFrame.
        if navigationAction.targetFrame?.isMainFrame == true,
           let s = navigationAction.request.url?.scheme?.lowercased(),
           s == "data" || s == "javascript" {
            decisionHandler(.cancel)
            return
        }

        // Hand non-web schemes (mailto:, facetime:, app links…) to the system —
        // but only for a top-level/new-window navigation, so a hidden sub-frame or
        // ad iframe can't silently launch someapp:// without a user action.
        if let url = navigationAction.request.url, let scheme = url.scheme?.lowercased(),
           !["http", "https", "file", "about", "data", "blob", "javascript", InternalScheme.scheme].contains(scheme) {
            let fromMainOrNewWindow = navigationAction.targetFrame?.isMainFrame ?? true
            if fromMainOrNewWindow { NSWorkspace.shared.open(url) }
            decisionHandler(.cancel)
            return
        }

        // Open a link in a new tab when WebKit signals a new-window navigation.
        // Three signals, any of which means "not the current frame":
        //  • targetFrame == nil  — target="_blank" / window-opening links that
        //    reach here instead of createWebViewWith
        //  • ⌘ held              — cmd-click
        //  • middle mouse button — buttonNumber 2
        // Programmatic same-frame loads carry none of these, so they fall
        // through to a normal in-tab navigation.
        // Site auto-routing: a top-level navigation to a host pinned to another
        // container is re-homed into a tab of that container. This is the thing
        // Firefox does with a clunky per-visit prompt — here it just happens.
        // The forked tab already carries the bound identity, so its own load of
        // the same host sees bound == current and passes through (no loop).
        if navigationAction.targetFrame?.isMainFrame == true,
           let url = navigationAction.request.url,
           let host = url.host,
           let boundID = IdentityStore.shared.routedIdentity(forHost: host),
           boundID != identityID(for: webView) {
            newTab(url: url, identityID: boundID)
            decisionHandler(.cancel)
            return
        }

        if let url = navigationAction.request.url {
            let mods = navigationAction.modifierFlags
            let cmdClick = mods.contains(.command)
            let middleClick = navigationAction.buttonNumber == 2
            let newWindow = navigationAction.targetFrame == nil
            if cmdClick || middleClick || newWindow {
                // ⌘-click and middle-click open a background tab (Chrome/Safari);
                // ⌘+Shift or an explicit _blank brings the new tab forward.
                let background = (cmdClick || middleClick) && !mods.contains(.shift)
                // Route by binding if the host is pinned, else inherit the
                // opener tab's identity so links stay in-container.
                let routedID = url.host.flatMap { IdentityStore.shared.routedIdentity(forHost: $0) }
                    ?? identityID(for: webView)
                newTab(url: url, background: background, identityID: routedID)
                decisionHandler(.cancel)
                return
            }
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if !navigationResponse.canShowMIMEType {
            decisionHandler(.download)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse,
                 didBecome download: WKDownload) {
        DownloadManager.shared.start(download, filename: navigationResponse.response.suggestedFilename ?? "download")
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction,
                 didBecome download: WKDownload) {
        DownloadManager.shared.start(download, filename: "download")
    }

    // MARK: WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Return a real web view built on WebKit's supplied configuration (which
        // carries the opener's process pool / data store and the window handle) so
        // window.open()/opener/postMessage and POST target=_blank all keep working
        // — returning nil (or making our own tab from the URL) drops the handle
        // and re-issues POSTs as GET. Decorate the config with our handlers first,
        // wrap the view in a tab that inherits the opener's container.
        WebViewFactory.applyCommonConfig(to: configuration)
        let popup = BrowserWebView(frame: .zero, configuration: configuration)
        let tab = Tab(webView: popup)
        tab.identityID = identityID(for: webView)
        tabManager.tabs.append(tab)
        switchToTab(tab)          // wires delegates + adds to the view hierarchy
        refreshTabBar()
        confirmToast("New tab opened", symbol: "plus.square.on.square")
        return popup              // WebKit drives the navigation into this view
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil)
    }

    // Camera / microphone. WebKit funnels getUserMedia here; without this the
    // system would silently deny. We honour a stored per-origin decision and
    // otherwise raise a formal prompt, storing the choice only if the user opts
    // to remember it. (Info.plist must carry NSCamera/NSMicrophoneUsageDescription
    // or macOS TCC aborts the app before this fires.)
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        guard let originKey = SitePermissionStore.origin(for: origin) else {
            decisionHandler(.deny)
            return
        }
        let store = SitePermissionStore.shared
        let perms: [SitePermission]
        switch type {
        case .camera: perms = [.camera]
        case .microphone: perms = [.microphone]
        case .cameraAndMicrophone: perms = [.camera, .microphone]
        @unknown default: perms = [.camera, .microphone]
        }

        // Any explicit deny short-circuits; grant requires every requested
        // permission already allowed.
        if perms.contains(where: { store.decision(originKey, $0) == .deny }) {
            decisionHandler(.deny); return
        }
        if perms.allSatisfy({ store.decision(originKey, $0) == .allow }) {
            decisionHandler(.grant); return
        }

        let what: String
        switch type {
        case .camera: what = "use your camera"
        case .microphone: what = "use your microphone"
        case .cameraAndMicrophone: what = "use your camera and microphone"
        @unknown default: what = "use your camera and microphone"
        }
        let alert = NSAlert()
        alert.messageText = "“\(origin.host)” wants to \(what)"
        alert.informativeText = "Allow this site to \(what)?"
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don’t Allow")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Remember this decision for \(origin.host)"
        let allow = alert.runModal() == .alertFirstButtonReturn
        if alert.suppressionButton?.state == .on {
            for p in perms { store.set(originKey, p, allow ? .allow : .deny) }
        }
        decisionHandler(allow ? .grant : .deny)
    }
}
