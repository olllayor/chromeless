import Cocoa
import CoreLocation
import LocalAuthentication
import Security
import WebKit

// MARK: - Downloads

struct DownloadItem {
    let id = UUID()
    let filename: String
    let destinationURL: URL
    var receivedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var status: Status = .running
    var resumeData: Data?
    enum Status { case running, completed, failed }

    /// Fraction complete when the total size is known, else nil (indeterminate).
    var fraction: Double? {
        totalBytes > 0 ? min(1, Double(receivedBytes) / Double(totalBytes)) : nil
    }
}

final class DownloadManager: NSObject, WKDownloadDelegate {
    static let shared = DownloadManager()
    var items: [DownloadItem] = []
    var onUpdate: (() -> Void)?
    private var activeDownloads: [ObjectIdentifier: DownloadItem] = [:]
    private var progressObservations: [ObjectIdentifier: NSKeyValueObservation] = [:]

    var hasItems: Bool { !items.isEmpty }
    var activeCount: Int { items.filter { $0.status == .running }.count }

    /// Combined fraction across all running downloads whose size is known.
    /// nil when nothing is downloading or no total is known (indeterminate).
    var activeProgress: Double? {
        let running = items.filter { $0.status == .running && $0.totalBytes > 0 }
        guard !running.isEmpty else { return nil }
        let recv = running.reduce(Int64(0)) { $0 + $1.receivedBytes }
        let total = running.reduce(Int64(0)) { $0 + $1.totalBytes }
        return total > 0 ? Double(recv) / Double(total) : nil
    }

    /// User-chosen download folder, falling back to ~/Downloads.
    static var destinationDirectory: URL {
        if let p = UserDefaults.standard.string(forKey: "DownloadDirectory"), !p.isEmpty {
            let u = URL(fileURLWithPath: p, isDirectory: true)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    func start(_ download: WKDownload, filename: String) {
        download.delegate = self
        // WKDownloadDelegate has no per-chunk data callback; byte progress lives
        // on WKDownload.progress (an NSProgress). Observe it for live updates.
        let key = ObjectIdentifier(download)
        progressObservations[key] = download.progress.observe(\.fractionCompleted, options: [.new]) {
            [weak self] prog, _ in
            let done = prog.completedUnitCount
            let total = prog.totalUnitCount
            DispatchQueue.main.async { self?.updateProgress(key, completed: done, total: total) }
        }
    }

    private func updateProgress(_ key: ObjectIdentifier, completed: Int64, total: Int64) {
        guard var item = activeDownloads[key],
              let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        item.receivedBytes = completed
        if total > 0 { item.totalBytes = total }
        items[idx] = item
        activeDownloads[key] = item
        onUpdate?()
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let downloads = DownloadManager.destinationDirectory
        var dest = downloads.appendingPathComponent(suggestedFilename)
        var counter = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            let name = (suggestedFilename as NSString).deletingPathExtension
            let ext = (suggestedFilename as NSString).pathExtension
            dest = downloads.appendingPathComponent("\(name) \(counter).\(ext)")
            counter += 1
        }
        var item = DownloadItem(filename: dest.lastPathComponent, destinationURL: dest)
        if response.expectedContentLength > 0 { item.totalBytes = response.expectedContentLength }
        items.append(item)
        activeDownloads[ObjectIdentifier(download)] = item
        onUpdate?()
        completionHandler(dest)
    }

    func downloadDidFinish(_ download: WKDownload) {
        let key = ObjectIdentifier(download)
        progressObservations.removeValue(forKey: key)
        guard var item = activeDownloads[key],
              let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        item.status = .completed
        item.receivedBytes = item.totalBytes > 0 ? item.totalBytes : item.receivedBytes
        items[idx] = item
        activeDownloads.removeValue(forKey: key)
        onUpdate?()
        DispatchQueue.main.async {
            if let wc = NSApp.keyWindow?.windowController as? BrowserWindowController {
                wc.showToast("Downloaded \(item.filename)")
            }
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let key = ObjectIdentifier(download)
        progressObservations.removeValue(forKey: key)
        guard var item = activeDownloads[key],
              let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        item.status = .failed
        item.resumeData = resumeData
        items[idx] = item
        activeDownloads.removeValue(forKey: key)
        onUpdate?()
    }

    /// Retry a failed download from its resume data. WebKit hands back a fresh
    /// WKDownload that re-enters the normal delegate flow (new row); the old
    /// failed entry is dropped so the list shows a single, live download.
    func resume(_ item: DownloadItem, in webView: WKWebView) {
        guard let data = item.resumeData else { return }
        items.removeAll { $0.id == item.id }
        onUpdate?()
        webView.resumeDownload(fromResumeData: data) { [weak self] download in
            download.delegate = self
        }
    }

    /// Reveal a finished download in Finder. Returns false if the file is gone
    /// (moved/deleted since the download completed).
    @discardableResult
    func revealInFinder(_ item: DownloadItem) -> Bool {
        guard FileManager.default.fileExists(atPath: item.destinationURL.path) else { return false }
        NSWorkspace.shared.activateFileViewerSelecting([item.destinationURL])
        return true
    }

    /// Open a finished download with its default app. Returns false if the file
    /// is gone or the OS refuses to open it.
    @discardableResult
    func openFile(_ item: DownloadItem) -> Bool {
        guard FileManager.default.fileExists(atPath: item.destinationURL.path) else { return false }
        return NSWorkspace.shared.open(item.destinationURL)
    }
}

/// A download list row that reveals-in-Finder (completed) or retries (failed) on
/// click, with a pointing-hand cursor to signal it's actionable.
/// Top-anchored container for the downloads list. Flipped so rows are laid out
/// from the top down with straightforward y math (an NSScrollView documentView
/// is otherwise bottom-origin).
final class DownloadsListView: NSView {
    override var isFlipped: Bool { true }
}

/// Toolbar downloads button (tray icon) that draws a determinate accent-colored
/// progress ring around itself while downloads are active.
final class DownloadsToolbarButton: NSButton {
    private let ring = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        isBordered = false
        bezelStyle = .inline
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        ring.fillColor = NSColor.clear.cgColor
        ring.lineWidth = 2
        ring.lineCap = .round
        ring.strokeEnd = 0
        ring.isHidden = true
        layer?.addSublayer(ring)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let inset: CGFloat = 2
        let r = min(bounds.width, bounds.height) / 2 - inset
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let path = CGMutablePath()
        // Start at 12 o'clock, sweep clockwise.
        path.addArc(center: center, radius: r,
                    startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        ring.path = path
        ring.frame = bounds
        ring.strokeColor = ChromeTheme.accent.cgColor
    }

    /// fraction 0…1 shows a determinate ring; nil hides it (idle / indeterminate).
    func setProgress(_ fraction: Double?) {
        if let f = fraction {
            ring.isHidden = false
            // Keep a sliver visible at 0 so the ring reads as "active".
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            ring.strokeEnd = CGFloat(max(0.03, min(1, f)))
            CATransaction.commit()
        } else {
            ring.isHidden = true
        }
    }
}

final class DownloadRow: NSView {
    var onClick: (() -> Void)?

    override func resetCursorRects() {
        // Only signal "clickable" when the whole row actually does something
        // (failed → retry). Completed rows act through their own buttons.
        if onClick != nil { addCursorRect(bounds, cursor: .pointingHand) }
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}

/// Compact pill button used by the autofill banner. Three looks that match the
/// app's dark HUD chrome: an accent-filled primary, a subtle translucent
/// secondary, and a borderless icon (the × dismiss). Runs a stored closure.
final class PillButton: NSButton {
    enum Kind { case primary, secondary, icon }
    var onClick: (() -> Void)?
    private let kind: Kind
    private var hovering = false

    init(title: String? = nil, symbol: String? = nil, kind: Kind, onClick: @escaping () -> Void) {
        self.kind = kind
        super.init(frame: .zero)
        self.onClick = onClick
        target = self
        action = #selector(fire)
        isBordered = false
        bezelStyle = .inline
        wantsLayer = true
        layer?.cornerRadius = kind == .icon ? 6 : 7
        layer?.cornerCurve = .continuous
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            imagePosition = .imageOnly
        }
        if let title { setTitle(title) }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setTitle(_ t: String) {
        let p = NSMutableParagraphStyle(); p.alignment = .center
        let color: NSColor = kind == .primary ? .white : .labelColor
        attributedTitle = NSAttributedString(string: t, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: color,
            .paragraphStyle: p,
        ])
    }

    override var intrinsicContentSize: NSSize {
        if kind == .icon { return NSSize(width: 22, height: 22) }
        var s = super.intrinsicContentSize
        s.width += 22
        s.height = 24
        return s
    }

    private func refresh() {
        switch kind {
        case .primary:
            layer?.backgroundColor = NSColor.controlAccentColor
                .withAlphaComponent(hovering ? 1.0 : 0.9).cgColor
        case .secondary:
            layer?.backgroundColor = NSColor.white
                .withAlphaComponent(hovering ? 0.16 : 0.09).cgColor
        case .icon:
            layer?.backgroundColor = (hovering ? NSColor.white.withAlphaComponent(0.12) : .clear).cgColor
            contentTintColor = hovering ? .secondaryLabelColor : .tertiaryLabelColor
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self, userInfo: nil))
    }
    override func mouseEntered(with e: NSEvent) { hovering = true; refresh() }
    override func mouseExited(with e: NSEvent) { hovering = false; refresh() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    @objc private func fire() { onClick?() }
}
