import Cocoa
import CoreLocation
import LocalAuthentication
import Security
import WebKit

// MARK: - ContentBlocker
//
// Ad/tracker blocking via WebKit's native WKContentRuleList. A curated set of
// third-party ad/tracker domains is compiled once into a content-rule bytecode
// list by WebKit itself — no extension host, no JS filtering engine. The
// compiled list is cached on disk by WKContentRuleListStore keyed on `identifier`
// and survives relaunches, so the compile cost is paid only when the list
// changes (bump the version suffix on `identifier` to force a recompile).
final class ContentBlocker {
    static let shared = ContentBlocker()

    // Bump the `-vN` suffix whenever `domains` changes so the cached
    // compilation is invalidated and WebKit recompiles the new list.
    private let identifier = "chromeless-blocker-v1"

    private var ruleList: WKContentRuleList?
    private var pending: [() -> Void] = []
    private(set) var enabled: Bool

    private init() {
        enabled = UserDefaults.standard.object(forKey: "ContentBlockingEnabled") as? Bool ?? true
    }

    /// Compile (or load from cache) the rule list. Call once at launch, before
    /// any web views are created — all state stays on the main thread.
    func prepare() {
        guard let store = WKContentRuleListStore.default() else { return }
        let done: (WKContentRuleList?) -> Void = { [weak self] list in
            guard let self, let list else { return }
            self.ruleList = list
            let jobs = self.pending
            self.pending.removeAll()
            jobs.forEach { $0() }
        }
        store.lookUpContentRuleList(forIdentifier: identifier) { [weak self] list, _ in
            guard let self else { return }
            if let list { done(list); return }
            store.compileContentRuleList(forIdentifier: self.identifier,
                                         encodedContentRuleList: Self.buildJSON()) { list, error in
                if let error {
                    fputs("chromeless: content blocker compile failed: \(error.localizedDescription)\n", stderr)
                }
                done(list)  // fail open — a nil list just means no blocking
            }
        }
    }

    /// Add or remove the compiled list on a user-content controller to match the
    /// current on/off state. If compilation hasn't finished, defers until it has.
    func apply(to controller: WKUserContentController) {
        guard let list = ruleList else {
            if enabled {
                pending.append { [weak self, weak controller] in
                    if let controller { self?.apply(to: controller) }
                }
            }
            return
        }
        if enabled { controller.add(list) } else { controller.remove(list) }
    }

    /// Toggle blocking and re-apply across all currently-open web views.
    func setEnabled(_ on: Bool, controllers: [WKUserContentController]) {
        enabled = on
        UserDefaults.standard.set(on, forKey: "ContentBlockingEnabled")
        controllers.forEach { apply(to: $0) }
    }

    /// Build the Apple content-blocker JSON from `domains`. Each domain becomes a
    /// third-party `block` rule matching the host and any subdomain. Building via
    /// JSONSerialization avoids hand-escaping backslashes in the regex.
    static func buildJSON() -> String {
        let rules: [[String: Any]] = domains.map { domain in
            let esc = NSRegularExpression.escapedPattern(for: domain)
            return [
                "trigger": [
                    "url-filter": "^https?://([^/]+\\.)?\(esc)",
                    "load-type": ["third-party"],
                ],
                "action": ["type": "block"],
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rules),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }

    /// Curated top ad/tracker domains (subset of EasyList/EasyPrivacy). Blocked
    /// only as third-party requests, so first-party site functionality is intact.
    static let domains: [String] = [
        // Google ads / analytics
        "doubleclick.net", "google-analytics.com", "googletagmanager.com",
        "googletagservices.com", "googlesyndication.com", "googleadservices.com",
        "adservice.google.com", "2mdn.net", "app-measurement.com",
        // Facebook / Meta
        "connect.facebook.net", "facebook.net", "pixel.facebook.com",
        // Amazon
        "amazon-adsystem.com", "assoc-amazon.com",
        // Microsoft / Bing
        "bat.bing.com", "clarity.ms",
        // Twitter/X
        "ads-twitter.com", "analytics.twitter.com", "static.ads-twitter.com",
        // Big ad exchanges / SSPs / DSPs
        "adnxs.com", "adsrvr.org", "rubiconproject.com", "pubmatic.com",
        "casalemedia.com", "bidswitch.net", "openx.net", "rlcdn.com",
        "3lift.com", "sharethrough.com", "gumgum.com", "smartadserver.com",
        "criteo.com", "criteo.net", "taboola.com", "outbrain.com",
        "adform.net", "teads.tv", "yieldmo.com", "indexww.com",
        "contextweb.com", "spotxchange.com", "spotx.tv", "adcolony.com",
        "inmobi.com", "mopub.com", "applovin.com", "unityads.unity3d.com",
        // Analytics / measurement / attribution
        "scorecardresearch.com", "quantserve.com", "quantcount.com",
        "moatads.com", "mixpanel.com", "segment.com", "segment.io",
        "branch.io", "amplitude.com", "hotjar.com", "crazyegg.com",
        "fullstory.com", "mouseflow.com", "chartbeat.com", "chartbeat.net",
        "newrelic.com", "nr-data.net", "optimizely.com", "kissmetrics.com",
        "heap.io", "heapanalytics.com", "keen.io", "loggly.com",
        "parsely.com", "tapad.com", "adroll.com",
        "getdrip.com", "clicktale.net", "sessioncam.com", "inspectlet.com",
        "cxense.com", "adobedtm.com", "demdex.net", "omtrdc.net",
        "everesttech.net", "2o7.net", "hs-analytics.net", "hubspot.com",
        // Consent / tag / audience
        "onetrust.com", "cookielaw.org", "ensighten.com", "tealium.com",
        "tealiumiq.com", "bluekai.com", "krxd.net", "agkn.com",
        "exelator.com", "mathtag.com", "bluecava.com", "eyeota.net",
        "liadm.com", "id5-sync.com", "crwdcntrl.net", "lijit.com",
        // Push / retargeting / misc trackers
        "pushcrew.com", "onesignal.com", "sail-horizon.com", "yieldlab.net",
        "servedbyadbutler.com", "adzerk.net", "revcontent.com", "mgid.com",
        "zergnet.com", "smartclip.net", "districtm.io", "sonobi.com",
        "media.net", "adblade.com", "adhigh.net", "adhese.com",
        "improvedigital.com", "emxdgt.com", "gammaplatform.com",
        "flashtalking.com", "serving-sys.com",
        "tremorhub.com", "bidr.io", "w55c.net", "simpli.fi",
        "turn.com", "dotomi.com", "rfihub.com", "mookie1.com",
    ]
}
