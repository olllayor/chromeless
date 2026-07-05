import Cocoa
import CoreLocation
import LocalAuthentication
import Security
import WebKit

// MARK: - Tabs

final class Tab {
    let id = UUID()
    let webView: BrowserWebView
    var title: String = ""
    var url: URL?
    var isLoading: Bool = false
    var isPlayingAudio: Bool = false
    var isMuted: Bool = false
    // (isPlayingAudio, isMuted) — the tab item needs both to pick the right icon.
    var onAudioStateChanged: ((Bool, Bool) -> Void)?
    var observations: [NSKeyValueObservation] = []
    private var audioPollTimer: Timer?

    init(webView: BrowserWebView) {
        self.webView = webView
        observations = [
            webView.observe(\.title) { [weak self] wv, _ in
                self?.title = wv.title ?? ""
            },
            webView.observe(\.url) { [weak self] wv, _ in
                self?.url = wv.url
            },
            webView.observe(\.isLoading) { [weak self] wv, _ in
                self?.isLoading = wv.isLoading
            },
        ]
        audioPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.pollAudioState()
        }
    }

    /// True only when the page is producing *audible* sound — WebKit's private
    /// `_isPlayingAudio` (what Safari uses for the tab speaker glyph). Unlike
    /// `requestMediaPlaybackState`, this is false for muted/silent/hidden media,
    /// so a plain page with an autoplay-muted element won't trip the icon.
    private var isAudible: Bool {
        let sel = NSSelectorFromString("_isPlayingAudio")
        guard webView.responds(to: sel) else { return false }
        return webView.value(forKey: "_isPlayingAudio") as? Bool ?? false
    }

    private func pollAudioState() {
        if isAudible {
            applyAudio(true)
        } else if isMuted {
            // Silent could just mean "muted, media still running" — keep the
            // (slashed) indicator until the media actually stops. Verify via
            // the media-playback state (which counts muted playback).
            webView.requestMediaPlaybackState { [weak self] state in
                self?.applyAudio(state == .playing)
            }
        } else {
            applyAudio(false)
        }
    }

    private func applyAudio(_ playing: Bool) {
        guard playing != isPlayingAudio else { return }
        isPlayingAudio = playing
        let muted = isMuted
        DispatchQueue.main.async { self.onAudioStateChanged?(playing, muted) }
    }

    /// Toggle the page's audio mute. WKWebView has no public mute property on
    /// macOS 13, so drive WebKit's `_setPageMuted:` (takes a `_WKMediaMutedState`
    /// bitmask; bit 0 = audio muted) through a typed IMP. Degrades to a no-op if
    /// the private selector is ever removed.
    func toggleMute() {
        isMuted.toggle()
        applyMute()
    }

    func applyMute() {
        let sel = NSSelectorFromString("_setPageMuted:")
        guard webView.responds(to: sel),
              let method = class_getInstanceMethod(type(of: webView), sel) else { return }
        typealias SetMutedFn = @convention(c) (AnyObject, Selector, UInt) -> Void
        let fn = unsafeBitCast(method_getImplementation(method), to: SetMutedFn.self)
        fn(webView, sel, isMuted ? 1 : 0)
    }

    deinit {
        audioPollTimer?.invalidate()
        observations.removeAll()
    }
}

/// Close button whose hover highlight is a rounded-rect fill (Helium-style)
/// rather than AppKit's default circular bezel treatment.
final class TabCloseButton: NSButton {
    private var trackingArea: NSTrackingArea?
    private var isHoveredOverButton = false {
        didSet { layer?.animateBackground(to: isHoveredOverButton
            ? NSColor.white.withAlphaComponent(0.14).cgColor : NSColor.clear.cgColor) }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.cornerCurve = .continuous
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let ta = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                 owner: self, userInfo: nil)
        addTrackingArea(ta)
        trackingArea = ta
    }

    override func mouseEntered(with event: NSEvent) { isHoveredOverButton = true }
    override func mouseExited(with event: NSEvent) { isHoveredOverButton = false }
}

/// Clickable audio/mute indicator with the same rounded-rect hover as the close
/// button. Sits just right of the favicon; clicking toggles the tab's mute.
final class TabAudioButton: NSButton {
    private var trackingArea: NSTrackingArea?
    private var isHoveredOverButton = false {
        didSet { layer?.animateBackground(to: isHoveredOverButton
            ? NSColor.white.withAlphaComponent(0.14).cgColor : NSColor.clear.cgColor) }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.cornerCurve = .continuous
        isBordered = false
        title = ""
        setButtonType(.momentaryChange)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let ta = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                 owner: self, userInfo: nil)
        addTrackingArea(ta)
        trackingArea = ta
    }

    override func mouseEntered(with event: NSEvent) { isHoveredOverButton = true }
    override func mouseExited(with event: NSEvent) { isHoveredOverButton = false }
}

final class TabBarItem: NSView, NSGestureRecognizerDelegate {

    static let minWidth: CGFloat = 108
    // Generous ceiling so a small number of tabs stretch to fill the strip
    // (Helium/Chrome expand-to-fill), only capping so a lone tab isn't absurd.
    static let maxWidth: CGFloat = 320

    /// Shown in a tab with no site favicon (start page, faviconless site).
    /// The full app icon buries the brand mark in squircle padding, so at tab
    /// size it looks tiny — draw a tight viewfinder-corners glyph that fills the
    /// favicon slot instead (same mark as the app icon, no padding).
    static let fallbackIcon: NSImage = {
        let s: CGFloat = 36
        let img = NSImage(size: NSSize(width: s, height: s))
        img.lockFocus()
        let box = NSRect(x: 4, y: 4, width: s - 8, height: s - 8)
        let arm: CGFloat = box.width * 0.34
        let p = NSBezierPath()
        p.lineWidth = 3.4
        p.lineCapStyle = .round
        p.lineJoinStyle = .round
        // Top-left
        p.move(to: NSPoint(x: box.minX, y: box.maxY - arm))
        p.line(to: NSPoint(x: box.minX, y: box.maxY))
        p.line(to: NSPoint(x: box.minX + arm, y: box.maxY))
        // Top-right
        p.move(to: NSPoint(x: box.maxX - arm, y: box.maxY))
        p.line(to: NSPoint(x: box.maxX, y: box.maxY))
        p.line(to: NSPoint(x: box.maxX, y: box.maxY - arm))
        // Bottom-right
        p.move(to: NSPoint(x: box.maxX, y: box.minY + arm))
        p.line(to: NSPoint(x: box.maxX, y: box.minY))
        p.line(to: NSPoint(x: box.maxX - arm, y: box.minY))
        // Bottom-left
        p.move(to: NSPoint(x: box.minX + arm, y: box.minY))
        p.line(to: NSPoint(x: box.minX, y: box.minY))
        p.line(to: NSPoint(x: box.minX, y: box.minY + arm))
        NSColor(calibratedWhite: 0.85, alpha: 1).setStroke()
        p.stroke()
        img.unlockFocus()
        return img
    }()

    // MARK: - Tab shape path helper

    private static let _pathCache = NSCache<NSString, CGPath>()

    private func tabShapePath(size: CGSize) -> CGPath {
        let key = "\(Int(size.width))x\(Int(size.height))" as NSString
        if let cached = Self._pathCache.object(forKey: key) { return cached }
        // Helium/Chrome-Refresh pill: all four corners rounded uniformly.
        let r: CGFloat = 8
        let rect = CGRect(origin: .zero, size: size)
        let path = CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
        Self._pathCache.setObject(path, forKey: key)
        return path
    }
    let index: Int
    let faviconView = NSImageView()
    let loadingSpinner = NSProgressIndicator()
    let audioButton = TabAudioButton()
    let titleLabel = NSTextField(labelWithString: "")
    let closeButton = TabCloseButton()
    var isSelected = false
    var isHovered = false
    var isLoading = false
    var isPlayingAudio = false {
        didSet {
            audioButton.isHidden = !isPlayingAudio
            needsLayout = true
        }
    }
    var isMuted = false {
        didSet { updateAudioIcon() }
    }
    private var shapeLayer: CAShapeLayer?
    private weak var target: AnyObject?
    private let clickAction: Selector
    private let closeAction: Selector
    private var secondaryAction: Selector?

    init(index: Int, title: String, favicon: NSImage?, isSelected: Bool, isLoading: Bool,
         target: AnyObject?, clickAction: Selector, closeAction: Selector,
         secondaryAction: Selector? = nil, audioAction: Selector? = nil) {
        self.index = index
        self.isSelected = isSelected
        self.isLoading = isLoading
        self.target = target
        self.clickAction = clickAction
        self.closeAction = closeAction
        self.secondaryAction = secondaryAction
        super.init(frame: .zero)

        wantsLayer = true

        faviconView.image = favicon ?? Self.fallbackIcon
        faviconView.imageScaling = .scaleProportionallyDown
        faviconView.setContentHuggingPriority(.required, for: .horizontal)
        faviconView.isHidden = isLoading
        addSubview(faviconView)

        loadingSpinner.style = .spinning
        loadingSpinner.controlSize = .small
        loadingSpinner.isDisplayedWhenStopped = false
        loadingSpinner.setContentHuggingPriority(.required, for: .horizontal)
        if isLoading { loadingSpinner.startAnimation(nil) }
        addSubview(loadingSpinner)

        // Mute/audio indicator: favicon first, this sits just right of it.
        // Clicking toggles the tab's mute.
        audioButton.contentTintColor = .secondaryLabelColor
        audioButton.target = target
        audioButton.action = audioAction
        audioButton.tag = index
        audioButton.isHidden = true
        addSubview(audioButton)
        updateAudioIcon()

        titleLabel.stringValue = title.isEmpty ? "New Tab" : title
        titleLabel.font = ChromeFont.tabTitle
        titleLabel.lineBreakMode = .byTruncatingTail
        (titleLabel.cell as? NSTextFieldCell)?.truncatesLastVisibleLine = true
        titleLabel.maximumNumberOfLines = 1
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(titleLabel)

        closeButton.title = ""
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: isSelected ? "xmark.circle.fill" : "xmark", accessibilityDescription: "Close tab")
        closeButton.contentTintColor = isSelected ? .secondaryLabelColor : .tertiaryLabelColor
        closeButton.target = target
        closeButton.action = closeAction
        closeButton.tag = index
        closeButton.setContentHuggingPriority(.required, for: .horizontal)
        closeButton.isHidden = true
        addSubview(closeButton)

        let click = NSClickGestureRecognizer(target: target, action: clickAction)
        click.delegate = self
        addGestureRecognizer(click)

        if let secondaryAction {
            let rightClick = NSClickGestureRecognizer(target: target, action: secondaryAction)
            rightClick.buttonMask = 0x2
            addGestureRecognizer(rightClick)
        }

        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError() }

    // The item-wide click gesture otherwise swallows clicks on the close button
    // (selecting the tab instead of closing it). Decline when the click lands on
    // the visible close button so its own action fires.
    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer,
                           shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        guard (gestureRecognizer as? NSClickGestureRecognizer)?.buttonMask == 0x1 else { return true }
        // Let the close button and audio/mute button receive their own clicks
        // instead of the item-wide select gesture swallowing them.
        for btn: NSButton in [closeButton, audioButton] where !btn.isHidden {
            let p = btn.convert(event.locationInWindow, from: nil)
            if btn.bounds.contains(p) { return false }
        }
        return true
    }

    private func updateAudioIcon() {
        let name = isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill"
        let cfg = NSImage.SymbolConfiguration(pointSize: 10.5, weight: .medium)
        audioButton.image = NSImage(systemSymbolName: name,
                                    accessibilityDescription: isMuted ? "Muted" : "Playing audio")?
            .withSymbolConfiguration(cfg)
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        let pad: CGFloat = 10
        let iconSize: CGFloat = 16
        let closeSize: CGFloat = 16
        let gap: CGFloat = 7
        // The audio/mute button gets its own square touch target sized close to the
        // favicon so the left cluster (favicon · speaker · title) reads evenly.
        let audioSize: CGFloat = 16
        let audioGap: CGFloat = 6

        // Favicon first (left edge), then the audio/mute button just right of it.
        faviconView.frame = NSRect(x: pad, y: (h - iconSize) / 2, width: iconSize, height: iconSize)
        loadingSpinner.frame = faviconView.frame

        var titleX = pad + iconSize + gap
        if isPlayingAudio {
            audioButton.frame = NSRect(x: titleX, y: (h - audioSize) / 2, width: audioSize, height: audioSize)
            titleX += audioSize + audioGap
        }
        let closeW = closeSize + 4
        let titleW = bounds.width - titleX - pad - closeW
        let titleH = ceil(ChromeFont.tabTitle.boundingRectForFont.height)
        titleLabel.frame = NSRect(x: titleX, y: (h - titleH) / 2, width: max(0, titleW), height: titleH)

        closeButton.frame = NSRect(x: bounds.width - pad - closeSize, y: (h - closeSize) / 2,
                                    width: closeSize, height: closeSize)

        // Update the tab shape path whenever layout changes
        updateShapePath()
    }

    private func updateShapePath() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        if shapeLayer == nil {
            let mask = CAShapeLayer()
            mask.frame = bounds
            mask.fillColor = NSColor.black.cgColor
            layer?.mask = mask
            shapeLayer = mask
        }
        shapeLayer?.frame = bounds
        shapeLayer?.path = tabShapePath(size: bounds.size)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateAppearance()
    }

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        ))
    }

    func updateAppearance() {
        // Helium: active tab is the omnibox-container surface floating above
        // the darker strip; inactive hover is that same surface at 45% alpha
        // (kTabInactiveHoverAlpha) — see ChromeTheme.
        let activeSurface = ChromeTheme.activeSurface
        let bg: CGColor
        if isSelected {
            bg = activeSurface.cgColor
            closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close tab")
            closeButton.contentTintColor = .secondaryLabelColor
            titleLabel.textColor = .labelColor
        } else if isHovered {
            bg = activeSurface.withAlphaComponent(ChromeTheme.tabHoverAlpha).cgColor
            closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")
            closeButton.contentTintColor = .secondaryLabelColor
            titleLabel.textColor = .labelColor
        } else {
            bg = NSColor.clear.cgColor
            closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")
            closeButton.contentTintColor = .tertiaryLabelColor
            // Inactive titles were tertiary (too faint to read) — bump to secondary.
            titleLabel.textColor = .secondaryLabelColor
        }
        layer?.animateBackground(to: bg)
        // Helium: the × appears only under the pointer — even on the active tab —
        // for a quieter strip.
        closeButton.isHidden = !isHovered
    }

    func update(title: String? = nil, favicon: NSImage? = nil, loading: Bool? = nil,
                playingAudio: Bool? = nil, muted: Bool? = nil) {
        if let title { titleLabel.stringValue = title.isEmpty ? "New Tab" : title }
        if let favicon { faviconView.image = favicon }
        if let loading {
            isLoading = loading
            faviconView.isHidden = loading
            if loading {
                loadingSpinner.startAnimation(nil)
            } else {
                loadingSpinner.stopAnimation(nil)
            }
        }
        if let playingAudio, playingAudio != isPlayingAudio {
            isPlayingAudio = playingAudio
        }
        if let muted, muted != isMuted { isMuted = muted }
    }
}

final class TabManager {
    var tabs: [Tab] = []
    private(set) var currentIndex: Int = 0
    private var mruOrder: [Tab] = []
    var current: Tab? {
        guard currentIndex >= 0, currentIndex < tabs.count else { return nil }
        return tabs[currentIndex]
    }
    var onTabsChanged: (() -> Void)?

    func select(_ tab: Tab) {
        guard let idx = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        currentIndex = idx
        mruOrder.removeAll { $0.id == tab.id }
        mruOrder.insert(tab, at: 0)
        onTabsChanged?()
    }

    func selectIndex(_ idx: Int) {
        guard idx >= 0, idx < tabs.count else { return }
        currentIndex = idx
        let tab = tabs[idx]
        mruOrder.removeAll { $0.id == tab.id }
        mruOrder.insert(tab, at: 0)
        onTabsChanged?()
    }

    func close(_ tab: Tab) {
        guard let idx = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: idx)
        mruOrder.removeAll { $0.id == tab.id }
        if idx <= currentIndex {
            currentIndex = max(0, currentIndex - 1)
        }
        if currentIndex >= tabs.count { currentIndex = max(0, tabs.count - 1) }
        onTabsChanged?()
    }

    func closeCurrent() {
        guard !tabs.isEmpty else { return }
        close(tabs[currentIndex])
    }

    func cycleMRU(backward: Bool) {
        guard mruOrder.count > 1 else { return }
        if backward {
            let last = mruOrder.removeLast()
            mruOrder.insert(last, at: 0)
        } else {
            let first = mruOrder.removeFirst()
            mruOrder.append(first)
        }
        select(mruOrder[0])
    }

    var count: Int { tabs.count }
    var isEmpty: Bool { tabs.isEmpty }

    /// Reorder a tab within the strip, keeping the selection on the same tab.
    func move(from: Int, to: Int) {
        guard from != to, tabs.indices.contains(from), tabs.indices.contains(to) else { return }
        let selected = current
        let t = tabs.remove(at: from)
        tabs.insert(t, at: to)
        if let selected, let idx = tabs.firstIndex(where: { $0.id == selected.id }) {
            currentIndex = idx
        }
        onTabsChanged?()
    }

    func replaceAll(with tab: Tab) {
        tabs = [tab]
        mruOrder = [tab]
        currentIndex = 0
        onTabsChanged?()
    }

    func closeAll(except keepTab: Tab) {
        let toClose = tabs.filter { $0.id != keepTab.id }
        for tab in toClose.reversed() {
            guard let idx = tabs.firstIndex(where: { $0.id == tab.id }) else { continue }
            tabs.remove(at: idx)
            mruOrder.removeAll { $0.id == tab.id }
            if idx <= currentIndex {
                currentIndex = max(0, currentIndex - 1)
            }
            if currentIndex >= tabs.count { currentIndex = max(0, tabs.count - 1) }
        }
        onTabsChanged?()
    }
}
