import Cocoa
import CoreLocation
import LocalAuthentication
import Security
import WebKit

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension NSColor {
    /// Parse a CSS-style hex color: "#RGB", "#RRGGBB", or "#RRGGBBAA" (leading
    /// "#" optional). Returns nil on malformed input.
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() } // #RGB → #RRGGBB
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let r, g, b, a: CGFloat
        if s.count == 8 {
            r = CGFloat((v >> 24) & 0xff) / 255
            g = CGFloat((v >> 16) & 0xff) / 255
            b = CGFloat((v >> 8) & 0xff) / 255
            a = CGFloat(v & 0xff) / 255
        } else {
            r = CGFloat((v >> 16) & 0xff) / 255
            g = CGFloat((v >> 8) & 0xff) / 255
            b = CGFloat(v & 0xff) / 255
            a = 1
        }
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }
}
