import Foundation
import Security

/// Whether a copy of the app is intact: every file signed and present. A copy taken while the app was being built and signed has
/// pieces missing; macOS then records its permissions (Full Disk Access) against that exact build instead of the developer's
/// identity, so every later build lost them, and it refuses to install the helper from it ("Codesigning failure loading plist …
/// -67056", 2026-10-05).
public enum CodeIntegrity {
    public static func isIntact(_ bundleURL: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &code) == errSecSuccess, let code else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        return SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess
    }
}
