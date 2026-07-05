import Cocoa
import CoreLocation
import LocalAuthentication
import Security
import WebKit

// MARK: - Theme
//
// Chromeless keeps its dark chrome, but adopts Helium's cooler accent + an
// optional grayscale scheme and a rounded web-content frame (Helium's
// kHeliumRoundedFrame). Accent flows into the settings page, the location-bar
// focus ring, and the site-settings popover.
enum ChromeTheme {
    /// Helium's signature blue — their kGoogleBlue600 replacement (#5578F4),
    /// the ramp value that reads on dark chrome.
    static let heliumBlue = NSColor(srgbRed: 0x55/255.0, green: 0x78/255.0, blue: 0xF4/255.0, alpha: 1)
    static let neutral = NSColor(srgbRed: 0x8A/255.0, green: 0x8A/255.0, blue: 0x92/255.0, alpha: 1)

    // Helium dark-chrome surfaces (helium-color-scheme/color-mixers patches).
    // Helium re-tints Chromium's neutral ramp slightly cool (G=B > R):
    //  • kColorSysHeader = Neutral12 #1E2020 — tab strip AND toolbar (one flat
    //    header block; stock Chrome makes the toolbar lighter than the frame).
    //  • Active tab = omnibox container = Neutral15 #242626 (Helium wires
    //    kColorTabBackgroundActiveFrameActive to kColorLocationBarBackground).
    //  • Inactive tab hover = the active-tab color at 45% alpha
    //    (kTabInactiveHoverAlpha = 0.45 * 255), not a white overlay.
    static let chromeSurface = NSColor(srgbRed: 0x1E/255.0, green: 0x20/255.0, blue: 0x20/255.0, alpha: 1)
    static let activeSurface = NSColor(srgbRed: 0x24/255.0, green: 0x26/255.0, blue: 0x26/255.0, alpha: 1)
    static let tabHoverAlpha: CGFloat = 0.45

    static var colorScheme: String { UserDefaults.standard.string(forKey: "ColorScheme") ?? "blue" }

    static var accent: NSColor { colorScheme == "grayscale" ? neutral : heliumBlue }

    /// CSS hex used to seed the settings page accent.
    static var accentHex: String { colorScheme == "grayscale" ? "#8a8a92" : "#5578f4" }

    static var roundedFrame: Bool { UserDefaults.standard.object(forKey: "RoundedFrame") as? Bool ?? true }
}

extension CALayer {
    /// Cross-fade the layer's background colour instead of snapping — used for
    /// hover states so they ease in/out rather than jump.
    func animateBackground(to color: CGColor?, duration: CFTimeInterval = 0.13) {
        let anim = CABasicAnimation(keyPath: "backgroundColor")
        anim.fromValue = backgroundColor
        anim.toValue = color
        anim.duration = duration
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        add(anim, forKey: "bgfade")
        backgroundColor = color
    }
}
