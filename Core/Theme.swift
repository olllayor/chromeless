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
    /// Helium's signature blue, tuned to read on the near-black chrome.
    static let heliumBlue = NSColor(srgbRed: 0x55/255.0, green: 0x78/255.0, blue: 0xF4/255.0, alpha: 1)
    static let neutral = NSColor(srgbRed: 0x8A/255.0, green: 0x8A/255.0, blue: 0x92/255.0, alpha: 1)

    static var colorScheme: String { UserDefaults.standard.string(forKey: "ColorScheme") ?? "blue" }

    static var accent: NSColor { colorScheme == "grayscale" ? neutral : heliumBlue }

    /// CSS hex used to seed the settings page accent.
    static var accentHex: String { colorScheme == "grayscale" ? "#8a8a92" : "#5578f4" }

    static var roundedFrame: Bool { UserDefaults.standard.object(forKey: "RoundedFrame") as? Bool ?? true }
}
