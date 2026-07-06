import Cocoa
import CoreLocation
import LocalAuthentication
import Security
import WebKit

// MARK: - Internal chromeless:// pages
//
// A custom scheme handler serving first-party pages (settings today; history /
// downloads later). Registered on every WKWebViewConfiguration so
// chromeless://settings is a real navigable, bookmarkable URL — the browser's
// own chrome://-style surface, styled to match the start page.
final class InternalScheme: NSObject, WKURLSchemeHandler {
    static let shared = InternalScheme()
    static let scheme = "chromeless"

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { task.didFailWithError(URLError(.badURL)); return }
        let page = url.host ?? "settings"
        let body: String
        switch page {
        case "settings": body = settingsHTML
        case "history": body = historyHTML
        case "accounts": body = accountsHTML
        default: body = "<!doctype html><meta charset=utf-8><body style='background:#0a0a0e'>"
        }
        let data = Data(body.utf8)
        let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "text/html; charset=utf-8",
                                                  "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'"])!
        task.didReceive(resp)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
