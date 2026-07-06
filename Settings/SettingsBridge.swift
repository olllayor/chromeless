import Cocoa
import CoreLocation
import LocalAuthentication
import Security
import WebKit

// MARK: - Settings bridge (JS ⇄ native)

/// Backs chromeless://settings. `get` returns a full snapshot; `set` writes one
/// key. Only honoured from the internal chromeless:// origin so no web page can
/// read/write preferences.
final class SettingsBridge: NSObject, WKScriptMessageHandler {
    static let shared = SettingsBridge()
    static let messageName = "clSettingsBridge"

    /// Bumped on every begin/end capture so a stale dead-man's-switch timer knows
    /// it's been superseded and skips restoring the menu.
    private var captureGen = 0

    func install(on config: WKWebViewConfiguration) {
        config.userContentController.add(self, name: Self.messageName)
    }

    private func snapshot() -> [String: Any] {
        let d = UserDefaults.standard
        return [
            "searchEngine": SearchEngine.current.rawValue,
            "searchEngines": SearchEngine.allCases.map { ["id": $0.rawValue, "label": $0.label] },
            "searchSuggestions": SearchEngine.suggestionsEnabled,
            "newTabNextToActive": d.object(forKey: "NewTabNextToActive") as? Bool ?? true,
            "restoreTabs": d.object(forKey: "RestoreTabsOnLaunch") as? Bool ?? true,
            "defaultZoom": d.object(forKey: "DefaultZoom") as? Double ?? 1.0,
            "blockAds": ContentBlocker.shared.enabled,
            "colorScheme": ChromeTheme.colorScheme,
            "accentHex": ChromeTheme.accentHex,
            "roundedFrame": ChromeTheme.roundedFrame,
            "centeredLocationBar": d.object(forKey: "CenteredLocationBar") as? Bool ?? true,
            "zenMode": d.bool(forKey: "ZenMode"),
            "autoHideSingleTab": d.object(forKey: "AutoHideSingleTab") as? Bool ?? true,
            "minimalAddressBar": d.bool(forKey: "MinimalAddressBar"),
            "autofillEnabled": Autofill.isEnabled,
            "confirmationToasts": d.object(forKey: "ConfirmationToasts") as? Bool ?? true,
            "prewarmTabs": WebViewFactory.prewarmEnabled,
            "bangs": Bangs.enabled,
            "linkPreview": d.object(forKey: "LinkPreviewBubble") as? Bool ?? true,
            "downloadDir": DownloadManager.destinationDirectory.path,
            "version": (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0",
        ]
    }

    /// Reply to a JS request that carried an `id`, resolving its pending promise.
    private func reply(_ webView: WKWebView, _ id: Any?, _ payload: Any) {
        guard let id else { return }
        guard let json = try? JSONSerialization.data(withJSONObject: payload),
              let s = String(data: json, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.__clSettings && window.__clSettings.reply(\(id), \(s));")
    }

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        // Trust only the internal origin.
        guard message.frameInfo.securityOrigin.`protocol` == InternalScheme.scheme,
              let body = message.body as? [String: Any],
              let action = body["action"] as? String,
              let webView = message.webView else { return }
        let id = body["id"]

        switch action {
        case "get":
            if let json = try? JSONSerialization.data(withJSONObject: snapshot()),
               let s = String(data: json, encoding: .utf8) {
                webView.evaluateJavaScript("window.__clSettings && window.__clSettings.state(\(s));")
            }
        case "set":
            guard let key = body["key"] as? String else { return }
            apply(key: key, value: body["value"])

        // --- Privacy: site permissions ---
        case "listPermissions":
            let store = SitePermissionStore.shared
            let rows = store.origins().map { origin -> [String: Any] in
                ["origin": origin,
                 "camera": store.decision(origin, .camera).rawValue,
                 "microphone": store.decision(origin, .microphone).rawValue]
            }
            reply(webView, id, rows)
        case "setPermission":
            if let origin = body["origin"] as? String,
               let perm = (body["permission"] as? String).flatMap(SitePermission.init(rawValue:)),
               let dec = (body["decision"] as? String).flatMap(PermissionDecision.init(rawValue:)) {
                SitePermissionStore.shared.set(origin, perm, dec)
            }
        case "resetSite":
            if let origin = body["origin"] as? String { SitePermissionStore.shared.reset(origin) }
        case "clearPermissions":
            SitePermissionStore.shared.clearAll()

        // --- History page (chromeless://history) ---
        case "historyList":
            let q = body["q"] as? String ?? ""
            let offset = body["offset"] as? Int ?? 0
            let rows = HistoryStore.shared.entries(query: q, limit: 100, offset: offset).map {
                ["url": $0.url, "title": $0.title, "t": $0.lastVisit] as [String: Any]
            }
            reply(webView, id, rows)
        case "historyDelete":
            if let u = body["url"] as? String { HistoryStore.shared.delete(url: u) }
            reply(webView, id, ["ok": true])
        case "historyClear":
            HistoryStore.shared.clearAll()
            reply(webView, id, ["ok": true])

        // --- Privacy: clear browsing data ---
        case "clearData":
            let flags = body["flags"] as? [String: Any] ?? [:]
            if flags["history"] as? Bool == true { HistoryStore.shared.clearAll() }
            var types = Set<String>()
            if flags["cookies"] as? Bool == true { types.insert(WKWebsiteDataTypeCookies) }
            if flags["cache"] as? Bool == true {
                types.formUnion([WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache,
                                 WKWebsiteDataTypeOfflineWebApplicationCache])
            }
            if types.isEmpty {
                reply(webView, id, ["ok": true])
            } else {
                WKWebsiteDataStore.default().removeData(ofTypes: types,
                                                        modifiedSince: Date(timeIntervalSince1970: 0)) {
                    self.reply(webView, id, ["ok": true])
                }
            }

        // --- Passwords ---
        case "listPasswords":
            let rows = Vault.allEntries().map { ["host": $0.host, "username": $0.username] }
            reply(webView, id, rows)
        case "deletePassword":
            if let host = body["host"] as? String, let u = body["username"] as? String {
                Vault.delete(host: host, username: u)
            }
        case "revealPassword":
            guard let host = body["host"] as? String, let u = body["username"] as? String else {
                reply(webView, id, ["error": "bad request"]); return
            }
            let ctx = LAContext()
            ctx.localizedReason = "reveal the saved password"
            var authErr: NSError?
            if ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &authErr) {
                ctx.evaluatePolicy(.deviceOwnerAuthentication,
                                   localizedReason: "reveal the saved password for \(host)") { ok, _ in
                    DispatchQueue.main.async {
                        if ok, let pw = Vault.reveal(host: host, username: u) {
                            self.reply(webView, id, ["password": pw])
                        } else {
                            self.reply(webView, id, ["error": "denied"])
                        }
                    }
                }
            } else if let pw = Vault.reveal(host: host, username: u) {
                reply(webView, id, ["password": pw]) // no biometrics available
            } else {
                reply(webView, id, ["error": "denied"])
            }

        // --- Downloads ---
        case "chooseDownloadDir":
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Choose"
            panel.directoryURL = DownloadManager.destinationDirectory
            if panel.runModal() == .OK, let url = panel.url {
                UserDefaults.standard.set(url.path, forKey: "DownloadDirectory")
            }
            reply(webView, id, ["path": DownloadManager.destinationDirectory.path])

        // --- Keyboard shortcuts ---
        case "listShortcuts":
            let kb = Keybindings.shared
            let rows = kb.commands.map { c -> [String: Any] in
                ["id": c.id, "title": c.title, "group": c.group,
                 "keys": kb.displayString(kb.current(c.id)),
                 "custom": kb.isCustomized(c.id)]
            }
            let system = kb.systemShortcuts.map { ["title": $0.title, "keys": $0.keys] }
            reply(webView, id, ["commands": rows, "system": system])
        case "setShortcut":
            guard let cid = body["cmd"] as? String,
                  let char = body["char"] as? String, !char.isEmpty else {
                reply(webView, id, ["error": "bad"]); return
            }
            var mods: NSEvent.ModifierFlags = []
            if body["meta"] as? Bool == true { mods.insert(.command) }
            if body["ctrl"] as? Bool == true { mods.insert(.control) }
            if body["alt"] as? Bool == true { mods.insert(.option) }
            if body["shift"] as? Bool == true { mods.insert(.shift) }
            // Require a non-Shift modifier so a binding can't swallow plain typing.
            guard mods.contains(.command) || mods.contains(.control) || mods.contains(.option) else {
                reply(webView, id, ["error": "needmod"]); return
            }
            let sc = Shortcut(key: char, mods: mods)
            if let reserved = Keybindings.shared.reservedReason(sc) {
                reply(webView, id, ["error": "reserved", "with": reserved]); return
            }
            if let other = Keybindings.shared.conflict(for: cid, sc) {
                let title = Keybindings.shared.commands.first { $0.id == other }?.title ?? other
                reply(webView, id, ["error": "conflict", "with": title]); return
            }
            Keybindings.shared.set(cid, sc)
            (NSApp.delegate as? AppDelegate)?.rebuildMenu()
            var out: [String: Any] = ["ok": true,
                                      "keys": Keybindings.shared.displayString(sc),
                                      "custom": Keybindings.shared.isCustomized(cid)]
            if let warn = Keybindings.shared.osWarning(sc) { out["warn"] = warn }
            reply(webView, id, out)
        case "resetShortcut":
            if let cid = body["cmd"] as? String {
                Keybindings.shared.reset(cid)
                (NSApp.delegate as? AppDelegate)?.rebuildMenu()
                reply(webView, id, ["keys": Keybindings.shared.displayString(Keybindings.shared.current(cid)),
                                    "custom": false])
            }
        case "resetAllShortcuts":
            Keybindings.shared.resetAll()
            (NSApp.delegate as? AppDelegate)?.rebuildMenu()
            reply(webView, id, ["ok": true])
        case "beginShortcutCapture":
            Keybindings.shared.suspended = true
            (NSApp.delegate as? AppDelegate)?.rebuildMenu()
            // Dead-man's switch: if the page never sends `end` (reload, JS crash,
            // tab closed mid-record) the menu would stay stripped forever. Restore
            // it automatically after a few seconds unless a newer capture began.
            captureGen &+= 1
            let gen = captureGen
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard let self, self.captureGen == gen, Keybindings.shared.suspended else { return }
                Keybindings.shared.suspended = false
                (NSApp.delegate as? AppDelegate)?.rebuildMenu()
            }
            reply(webView, id, ["ok": true])
        case "endShortcutCapture":
            captureGen &+= 1 // invalidate any pending auto-restore
            Keybindings.shared.suspended = false
            (NSApp.delegate as? AppDelegate)?.rebuildMenu()
            reply(webView, id, ["ok": true])

        default:
            break
        }
    }

    private func apply(key: String, value: Any?) {
        let d = UserDefaults.standard
        switch key {
        case "searchEngine":
            if let s = value as? String, SearchEngine(rawValue: s) != nil {
                d.set(s, forKey: "DefaultSearchEngine")
            }
        case "searchSuggestions":
            if let b = value as? Bool { d.set(b, forKey: "SearchSuggestions") }
        case "newTabNextToActive":
            if let b = value as? Bool { d.set(b, forKey: "NewTabNextToActive") }
        case "restoreTabs":
            if let b = value as? Bool { d.set(b, forKey: "RestoreTabsOnLaunch") }
        case "defaultZoom":
            if let z = value as? Double { d.set(z, forKey: "DefaultZoom") }
        case "blockAds":
            if let b = value as? Bool {
                (NSApp.delegate as? AppDelegate)?.setContentBlocking(b)
            }
        case "colorScheme":
            if let s = value as? String, s == "blue" || s == "grayscale" {
                d.set(s, forKey: "ColorScheme")
                (NSApp.delegate as? AppDelegate)?.refreshAllChrome()
            }
        case "roundedFrame":
            if let b = value as? Bool {
                d.set(b, forKey: "RoundedFrame")
                (NSApp.delegate as? AppDelegate)?.refreshAllChrome()
            }
        case "centeredLocationBar":
            if let b = value as? Bool {
                d.set(b, forKey: "CenteredLocationBar")
                (NSApp.delegate as? AppDelegate)?.refreshAllChrome()
            }
        case "zenMode":
            if let b = value as? Bool {
                // setZenMode writes the pref itself + animates/toasts per window.
                (NSApp.delegate as? AppDelegate)?.setZenModeAll(b)
            }
        case "autoHideSingleTab":
            if let b = value as? Bool {
                d.set(b, forKey: "AutoHideSingleTab")
                (NSApp.delegate as? AppDelegate)?.refreshAllChrome()
            }
        case "minimalAddressBar":
            if let b = value as? Bool {
                d.set(b, forKey: "MinimalAddressBar")
                (NSApp.delegate as? AppDelegate)?.refreshAllChrome()
            }
        case "autofillEnabled":
            if let b = value as? Bool { d.set(b, forKey: "AutofillEnabled") }
        case "confirmationToasts":
            if let b = value as? Bool { d.set(b, forKey: "ConfirmationToasts") }
        case "prewarmTabs":
            if let b = value as? Bool {
                d.set(b, forKey: "PrewarmTabs")
                if b { WebViewFactory.prewarm() } else { WebViewFactory.discardSpare() }
            }
        case "bangs":
            if let b = value as? Bool { d.set(b, forKey: "BangsEnabled") }
        case "linkPreview":
            if let b = value as? Bool { d.set(b, forKey: "LinkPreviewBubble") }
        default:
            break
        }
    }
}
