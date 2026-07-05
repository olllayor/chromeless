import Cocoa
import CoreLocation
import LocalAuthentication
import Security
import WebKit

// MARK: - Passkey capability

// WKWebView performs WebAuthn (passkeys via iCloud Keychain / Touch ID) only for
// apps signed with Apple's restricted web-browser.public-key-credential
// entitlement, which needs an Apple-issued provisioning profile — macOS kills
// ad-hoc builds that claim it. So: if this build carries the entitlement,
// passkeys just work; if not, hide the WebAuthn API so sites feature-detect the
// absence and offer their fallback sign-in (password, phone prompt) instead of
// a passkey ceremony that is guaranteed to fail. See README for enabling it.
let hasPasskeyEntitlement: Bool = {
    guard let task = SecTaskCreateFromSelf(nil) else { return false }
    let value = SecTaskCopyValueForEntitlement(
        task, "com.apple.developer.web-browser.public-key-credential" as CFString, nil)
    return (value as? Bool) == true
}()
