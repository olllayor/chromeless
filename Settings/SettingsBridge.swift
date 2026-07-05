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
