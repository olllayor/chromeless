import Cocoa
import CoreLocation
import LocalAuthentication
import Security
import WebKit

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
