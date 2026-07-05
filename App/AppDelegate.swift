import Cocoa
import CoreLocation
import LocalAuthentication
import Security
import WebKit

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var controllers: [BrowserWindowController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        UserDefaults.standard.register(defaults: ["NewTabNextToActive": true, "RoundedFrame": true, "AutoHideSingleTab": true])
        ContentBlocker.shared.prepare()
        buildMenu()

        let urlsToRestore: [URL] = {
            if let u = launchOptions.url { return [u] }
            if launchOptions.snap != nil { return [] }
            // Honour the "Restore tabs on launch" setting (default on).
            guard UserDefaults.standard.object(forKey: "RestoreTabsOnLaunch") as? Bool ?? true else { return [] }
            if let saved = UserDefaults.standard.array(forKey: "OpenTabs") as? [String],
               !saved.isEmpty {
                return saved.compactMap { URL(string: $0) }
            }
            if let s = UserDefaults.standard.string(forKey: "LastURL"),
               let url = URL(string: s) {
                return [url]
            }
            return []
        }()

        if urlsToRestore.isEmpty {
            openWindow(url: nil, size: launchOptions.size, snap: launchOptions.snap, isPrimary: true)
        } else {
            openWindow(url: urlsToRestore.first, size: launchOptions.size, snap: launchOptions.snap, isPrimary: true)
            if let primaryController = controllers.first {
                for url in urlsToRestore.dropFirst() {
                    primaryController.newTab(url: url)
                }
            }
        }
        NSApp.activate(ignoringOtherApps: true)

        // Bank a pre-built web view once launch settles so the first ⌘T is
        // instant (config + view alloc off the critical path).
        DispatchQueue.main.async { WebViewFactory.prewarm() }

        if launchOptions.snap != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                fputs("chromeless: --snap timed out\n", stderr)
                exit(2)
            }
        }
    }

    func openWindow(url: URL?, size: NSSize? = nil, snap: SnapJob? = nil, isPrimary: Bool = false) {
        let controller = BrowserWindowController(url: url, size: size, snap: snap, isPrimary: isPrimary)
        controller.onClose = { [weak self, weak controller] in
            self?.controllers.removeAll { $0 === controller }
        }
        controllers.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    @objc func newWindow(_ sender: Any?) { openWindow(url: nil) }

    @objc func openLocation(_ sender: Any?) {
        (NSApp.keyWindow?.windowController as? BrowserWindowController)?.focusURLField()
    }

    @objc func toggleContentBlocking(_ sender: NSMenuItem) {
        let on = !ContentBlocker.shared.enabled
        setContentBlocking(on)
        sender.state = on ? .on : .off
    }

    /// Re-apply theme-driven chrome across every open window (rounded frame, accent).
    func refreshAllChrome() {
        controllers.forEach { $0.applyChromeSettings() }
    }

    /// Toggle zen/frameless mode across every open window (from the settings page).
    func setZenModeAll(_ on: Bool) {
        controllers.forEach { $0.setZenMode(enabled: on) }
    }

    /// Enable/disable content blocking across every open tab. Shared by the View
    /// menu toggle and the settings page.
    func setContentBlocking(_ on: Bool) {
        let controllers = self.controllers.flatMap { wc in
            wc.tabManager.tabs.map { $0.webView.configuration.userContentController }
        }
        ContentBlocker.shared.setEnabled(on, controllers: controllers)
        // The banked spare web view was configured under the old blocking
        // state — rebuild it so the next tab matches.
        WebViewFactory.discardSpare()
        WebViewFactory.prewarm()
    }

    @objc func openSettings(_ sender: Any?) {
        let url = URL(string: "\(InternalScheme.scheme)://settings")!
        if let wc = controllers.first(where: { $0.window?.isKeyWindow == true }) ?? controllers.first {
            wc.newTab(url: url)
        } else {
            openWindow(url: url)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        var tabURLs: [String] = []
        for wc in controllers {
            for tab in wc.tabManager.tabs {
                if let url = tab.url?.absoluteString {
                    tabURLs.append(url)
                }
            }
        }
        UserDefaults.standard.set(tabURLs, forKey: "OpenTabs")
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { openWindow(url: url) }
    }

    // MARK: Menu

    private func buildMenu() {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Chromeless",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Chromeless", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                                         action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Chromeless", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(withTitle: "Chromeless", action: nil, keyEquivalent: "").submenu = appMenu

        let fileMenu = NSMenu(title: "File")
        let newWin = fileMenu.addItem(withTitle: "New Window", action: #selector(newWindow(_:)), keyEquivalent: "n")
        newWin.target = self
        let openLocation = fileMenu.addItem(withTitle: "Open Location…",
                                            action: #selector(AppDelegate.openLocation(_:)), keyEquivalent: "l")
        openLocation.target = self
        fileMenu.addItem(.separator())
        let snap = fileMenu.addItem(withTitle: "Save Snapshot to Desktop",
                                    action: #selector(BrowserWindowController.saveSnapshot(_:)), keyEquivalent: "s")
        snap.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "New Tab",
                         action: #selector(AppDelegate.newTab(_:)), keyEquivalent: "t")
        // Uppercase "T" auto-implies Shift for both display and matching — a
        // lowercase "t" with an explicit shift mask never matches, because the
        // event's charactersIgnoringModifiers already carries the shift ("T").
        let reopenTab = fileMenu.addItem(withTitle: "Reopen Closed Tab",
                                         action: #selector(AppDelegate.reopenClosedTab(_:)), keyEquivalent: "T")
        reopenTab.target = self
        fileMenu.addItem(withTitle: "Close Tab",
                         action: #selector(AppDelegate.closeTab(_:)), keyEquivalent: "w")
        fileMenu.addItem(withTitle: "Close Window",
                         action: #selector(NSWindow.performClose(_:)), keyEquivalent: "W")
        main.addItem(withTitle: "File", action: nil, keyEquivalent: "").submenu = fileMenu

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: NSSelectorFromString("redo:"), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        let copyURL = editMenu.addItem(withTitle: "Copy Current URL",
                                       action: #selector(BrowserWindowController.copyPageURL(_:)), keyEquivalent: "c")
        copyURL.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Find…",
                         action: #selector(BrowserWindowController.showFindBar(_:)), keyEquivalent: "f")
        editMenu.addItem(withTitle: "Find Next",
                         action: #selector(BrowserWindowController.findNext(_:)), keyEquivalent: "g")
        editMenu.addItem(withTitle: "Find Previous",
                         action: #selector(BrowserWindowController.findPrev(_:)), keyEquivalent: "G")
        main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = editMenu

        let bookmarksMenu = NSMenu(title: "Bookmarks")
        bookmarksMenu.delegate = self
        bookmarksMenu.addItem(withTitle: "Add Bookmark…",
                              action: #selector(BrowserWindowController.addBookmark(_:)), keyEquivalent: "d")
        bookmarksMenu.addItem(.separator())
        main.addItem(withTitle: "Bookmarks", action: nil, keyEquivalent: "").submenu = bookmarksMenu

        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Reload Page",
                         action: #selector(BrowserWindowController.reloadPage(_:)), keyEquivalent: "r")
        let hardReload = viewMenu.addItem(withTitle: "Reload Ignoring Cache",
                                          action: #selector(BrowserWindowController.hardReloadPage(_:)), keyEquivalent: "r")
        hardReload.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Zoom In",
                         action: #selector(BrowserWindowController.zoomInPage(_:)), keyEquivalent: "=")
        // Hidden alternate so ⌘+ (⌘⇧=) also zooms in, not just ⌘=.
        let zoomInPlus = viewMenu.addItem(withTitle: "Zoom In",
                                          action: #selector(BrowserWindowController.zoomInPage(_:)), keyEquivalent: "+")
        zoomInPlus.keyEquivalentModifierMask = [.command, .shift]
        zoomInPlus.isAlternate = true
        viewMenu.addItem(withTitle: "Zoom Out",
                         action: #selector(BrowserWindowController.zoomOutPage(_:)), keyEquivalent: "-")
        viewMenu.addItem(withTitle: "Actual Size",
                         action: #selector(BrowserWindowController.resetZoom(_:)), keyEquivalent: "0")
        viewMenu.addItem(.separator())
        let pip = viewMenu.addItem(withTitle: "Picture in Picture",
                                   action: #selector(BrowserWindowController.togglePictureInPicture(_:)), keyEquivalent: "p")
        pip.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(.separator())
        let fullScreen = viewMenu.addItem(withTitle: "Enter Full Screen",
                                          action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        // Uppercase "L" implies Shift → matches ⌘⇧L (⌘L is Open Location).
        viewMenu.addItem(withTitle: "Frameless Mode",
                         action: #selector(BrowserWindowController.toggleZenMode(_:)), keyEquivalent: "L")
        // Uppercase "E" → ⌘⇧E. Pairs the active tab with the next one.
        viewMenu.addItem(withTitle: "Split View",
                         action: #selector(BrowserWindowController.toggleSplitView(_:)), keyEquivalent: "E")
        viewMenu.addItem(.separator())
        let blockAds = viewMenu.addItem(withTitle: "Block Ads & Trackers",
                                        action: #selector(toggleContentBlocking(_:)), keyEquivalent: "")
        blockAds.target = self
        blockAds.state = ContentBlocker.shared.enabled ? .on : .off
        main.addItem(withTitle: "View", action: nil, keyEquivalent: "").submenu = viewMenu

        let historyMenu = NSMenu(title: "History")
        historyMenu.delegate = self
        historyMenu.addItem(withTitle: "Back",
                            action: #selector(BrowserWindowController.goBackAction(_:)), keyEquivalent: "[")
        historyMenu.addItem(withTitle: "Forward",
                            action: #selector(BrowserWindowController.goForwardAction(_:)), keyEquivalent: "]")
        main.addItem(withTitle: "History", action: nil, keyEquivalent: "").submenu = historyMenu

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Pin on Top",
                           action: #selector(BrowserWindowController.togglePin(_:)), keyEquivalent: "p")
        windowMenu.addItem(withTitle: "Downloads",
                           action: #selector(BrowserWindowController.toggleDownloads(_:)), keyEquivalent: "j")
            .keyEquivalentModifierMask = [.command, .shift]
        windowMenu.addItem(withTitle: "Tab Bar",
                           action: #selector(BrowserWindowController.toggleTabBar(_:)), keyEquivalent: "t")
            .keyEquivalentModifierMask = [.option, .command]
        main.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(withTitle: "Chromeless Help",
                         action: #selector(BrowserWindowController.showHelpPage(_:)), keyEquivalent: "?")
        main.addItem(withTitle: "Help", action: nil, keyEquivalent: "").submenu = helpMenu
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = main
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu.title == "History" {
            menu.removeAllItems()
            menu.addItem(withTitle: "Back", action: #selector(BrowserWindowController.goBackAction(_:)), keyEquivalent: "[")
            menu.addItem(withTitle: "Forward", action: #selector(BrowserWindowController.goForwardAction(_:)), keyEquivalent: "]")
            menu.addItem(.separator())
            let recent = HistoryStore.shared.recentItems(limit: 10)
            for item in recent {
                let mi = menu.addItem(withTitle: item.title.isEmpty ? item.url : item.title,
                                      action: #selector(openHistoryItem(_:)), keyEquivalent: "")
                mi.representedObject = item.url
                mi.target = self
            }
            if !recent.isEmpty { menu.addItem(.separator()) }
            menu.addItem(withTitle: "Clear History…",
                         action: #selector(clearHistory(_:)), keyEquivalent: "")
        }
        if menu.title == "Bookmarks" {
            let existing = menu.items.filter { $0.tag == 100 }
            existing.forEach { menu.removeItem($0) }
            let bookmarks = BookmarkStore.shared.allBookmarks()
            if !bookmarks.isEmpty {
                let sep = NSMenuItem.separator()
                sep.tag = 100
                menu.addItem(sep)
            }
            for bm in bookmarks.prefix(20) {
                let mi = menu.addItem(withTitle: bm.title, action: #selector(openBookmark(_:)), keyEquivalent: "")
                mi.representedObject = bm.url
                mi.target = self
                mi.tag = 100
            }
        }
    }

    @objc func openBookmark(_ sender: NSMenuItem) {
        guard let urlString = sender.representedObject as? String,
              let url = URL(string: urlString) else { return }
        if let wc = NSApp.keyWindow?.windowController as? BrowserWindowController {
            wc.navigate(to: url)
        }
    }

    @objc func newTab(_ sender: Any?) {
        if let wc = NSApp.keyWindow?.windowController as? BrowserWindowController {
            wc.newTab()
        } else {
            openWindow(url: nil)
        }
    }

    @objc func closeTab(_ sender: Any?) {
        if let wc = NSApp.keyWindow?.windowController as? BrowserWindowController {
            wc.closeCurrentTab()
        }
    }

    @objc func reopenClosedTab(_ sender: Any?) {
        if let wc = NSApp.keyWindow?.windowController as? BrowserWindowController {
            wc.reopenClosedTab(sender)
        } else if let url = ClosedTabStore.pop() {
            openWindow(url: url)
        }
    }

    @objc func openHistoryItem(_ sender: NSMenuItem) {
        guard let urlString = sender.representedObject as? String,
              let url = URL(string: urlString) else { return }
        if let wc = NSApp.keyWindow?.windowController as? BrowserWindowController {
            wc.navigate(to: url)
        }
    }

    @objc func clearHistory(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Clear all browsing history?"
        alert.informativeText = "This cannot be undone."
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            HistoryStore.shared.clearAll()
        }
    }
}
