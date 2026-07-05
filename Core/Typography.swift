import Cocoa
import CoreLocation
import LocalAuthentication
import Security
import WebKit

// MARK: - Chrome typography

enum ChromeFont {
    static let tabTitle = NSFont.systemFont(ofSize: 12)
    static let urlField = NSFont.systemFont(ofSize: 14)
    static let hudField = NSFont.systemFont(ofSize: 16)
    static let findField = NSFont.systemFont(ofSize: 14)
    static let findStatus = NSFont.systemFont(ofSize: 12)
    static let toast = NSFont.systemFont(ofSize: 13, weight: .medium)
    static let suggestionTitle = NSFont.systemFont(ofSize: 12)
    static let suggestionURL = NSFont.systemFont(ofSize: 10)
    static let hudSuggestionTitle = NSFont.systemFont(ofSize: 13)
    static let hudSuggestionURL = NSFont.systemFont(ofSize: 11)
    static let downloadTitle = NSFont.systemFont(ofSize: 12)
    static let downloadStatus = NSFont.systemFont(ofSize: 11)

    static func placeholder(_ string: String, font: NSFont, color: NSColor,
                            alignment: NSTextAlignment = .natural) -> NSAttributedString {
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if alignment != .natural {
            let style = NSMutableParagraphStyle()
            style.alignment = alignment
            attrs[.paragraphStyle] = style
        }
        return NSAttributedString(string: string, attributes: attrs)
    }
}
