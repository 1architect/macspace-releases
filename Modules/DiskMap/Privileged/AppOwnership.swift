import Foundation
import AppKit
import CryptoKit
import Security
import Darwin
import MacSpacePlatform

/// Ownership comes from bundle identifiers, signed app groups and declared helper requirements, never substring matches.
public struct AppOwner: Codable, Equatable, Sendable {
    public var path: String
    public var identifier: String
    public var name: String
    public var groups: [String]
    public var helpers: [String: String]
    public var team: String?
    public var identifiers: Set<String>
    public var isBackground: Bool
    public var signatureValid: Bool
    public var metadataDigest: String
    public var codeDirectoryDigest: String?
    public init?(path: String, knownIdentifiers: Set<String>? = nil, verifySignature: Bool = false) {
        let url = URL(fileURLWithPath: path)
        var metadata = stat()
        guard lstat(path, &metadata) == 0, metadata.st_flags & UInt32(SF_DATALESS) == 0,
              lstat(path + "/Contents", &metadata) == 0, metadata.st_flags & UInt32(SF_DATALESS) == 0,
              lstat(path + "/Contents/Info.plist", &metadata) == 0, metadata.st_flags & UInt32(SF_DATALESS) == 0 else { return nil }
        guard url.pathExtension == "app", let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) as? [String: Any],
              let identifier = info["CFBundleIdentifier"] as? String, Self.validIdentifier(identifier) else { return nil }
        guard let infoData = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")) else { return nil }
        metadataDigest = SHA256.hash(data: infoData).map { String(format: "%02x", $0) }.joined()
        self.path = path; self.identifier = identifier
        name = info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? url.deletingPathExtension().lastPathComponent
        isBackground = info["LSBackgroundOnly"] as? Bool == true
        // Read signing identity/entitlements without validating every byte of every installed app during browsing.
        // Destructive execution validates the selected app separately.
        let signing = Self.signing(path)
        signatureValid = verifySignature && Self.validSignature(path)
        codeDirectoryDigest = (signing?[kSecCodeInfoUnique as String] as? Data)?.base64EncodedString()
        team = signing?[kSecCodeInfoTeamIdentifier as String] as? String
        let entitlements = signing?[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        groups = (entitlements?["com.apple.security.application-groups"] as? [String] ?? []).filter(Self.validIdentifier)
        identifiers = Set((knownIdentifiers ?? []).filter { Self.validIdentifier($0) }).union([identifier])
        helpers = signing != nil ? (info["SMPrivilegedExecutables"] as? [String: String] ?? [:]).filter { Self.validIdentifier($0.key) } : [:]
    }
    public static func validIdentifier(_ id: String) -> Bool {
        id.contains(".") && id.count < 240 && id.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]+$", options: .regularExpression) != nil
    }
    public static func validSignature(_ path: String) -> Bool {
        var code: SecStaticCode?
        return SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess
            && code.map { SecStaticCodeCheckValidity($0, [], nil) == errSecSuccess } == true
    }
    public static func helperMatches(_ path: String, requirement: String, team: String?) -> Bool {
        guard let team, signing(path)?[kSecCodeInfoTeamIdentifier as String] as? String == team else { return false }
        var code: SecStaticCode?; var rule: SecRequirement?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
              SecRequirementCreateWithString(requirement as CFString, [], &rule) == errSecSuccess, let code, let rule else { return false }
        return SecStaticCodeCheckValidity(code, [], rule) == errSecSuccess
    }
    public static func signing(_ path: String) -> [String: Any]? {
        var code: SecStaticCode?; var info: CFDictionary?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess else { return nil }
        return info as? [String: Any]
    }
}

public enum AppOwnership {
    public static func discover(home: String, candidates: [String] = []) -> AppCatalog {
        var paths = Set<String>(), registered = Set<String>()
        for root in ["/Applications", home + "/Applications", "/System/Applications"] {
            guard let iterator = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in iterator {
                if Task.isCancelled { return AppCatalog(owners: []) }
                var st = stat()
                guard lstat(url.path, &st) == 0, st.st_flags & UInt32(SF_DATALESS) == 0, st.st_mode & S_IFMT != S_IFLNK else { iterator.skipDescendants(); continue }
                if url.pathExtension == "app" { paths.insert(url.path); iterator.skipDescendants() }
            }
        }
        paths.formUnion(candidates.filter { !$0.contains(".app/") && !$0.contains("/.Trash/") && !$0.contains("/.Trashes/") })
        // Public registration lookup by known bundle ID. There is no claim of a complete global registration inventory.
        let seeds = paths.compactMap { path in Task.isCancelled ? nil : autoreleasepool { AppOwner(path: path, knownIdentifiers: []) } }
        for id in Set(seeds.map(\.identifier)) {
            if Task.isCancelled { return AppCatalog(owners: []) }
            let registeredPaths = autoreleasepool { NSWorkspace.shared.urlsForApplications(withBundleIdentifier: id).map(\.path) }
            for path in registeredPaths {
                if safeExisting(path) { paths.insert(path); registered.insert(path) }
            }
        }
        let prior = Dictionary(seeds.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        return AppCatalog(owners: paths.sorted().compactMap { path in Task.isCancelled ? nil : autoreleasepool { prior[path] ?? AppOwner(path: path, knownIdentifiers: []) } }, registeredPaths: registered)
    }
    public static func installed(home: String) -> [AppOwner] { discover(home: home).owners }
    public static func classification(_ owner: AppOwner, home: String, registered: Set<String> = [], candidates: [AppOwner] = []) -> (AppClassification, String) {
        if owner.identifier == "com.macspace" || owner.identifier.hasPrefix("com.macspace.") { return (.macSpaceLifecycle, "Use MacSpace's dedicated uninstall lifecycle.") }
        if owner.path.hasPrefix("/System/") || owner.path.hasPrefix("/usr/") { return (.protectedSystem, "Protected operating-system location.") }
        var protection = stat()
        if lstat(owner.path, &protection) == 0, protection.st_flags & UInt32(SF_RESTRICTED | SF_IMMUTABLE | UF_IMMUTABLE) != 0 {
            return (.protectedSystem, "Filesystem protection or immutable flags prevent ordinary removal.")
        }
        if !safeExisting(owner.path) { return (.extraCopy, "Unavailable or symbolic-link installation.") }
        let inApplications = owner.path.hasPrefix("/Applications/") || owner.path.hasPrefix(home + "/Applications/")
        // A standalone menu-bar app in Applications has the same removal lifecycle as any installed app.
        if owner.isBackground { return (.background, "Background or agent application; lifecycle removal needs separate review.") }
        let preferredCopy = candidates.contains { other in
            other.path != owner.path && other.identifier == owner.identifier && other.team == owner.team
                && (other.path.hasPrefix("/Applications/") || other.path.hasPrefix(home + "/Applications/"))
        }
        if inApplications || (registered.contains(owner.path) && !preferredCopy) {
            return (.installedUser, "Installed application; only reviewed verified targets may be removed.")
        }
        return (.extraCopy, "Outside application folders and not confirmed by public registration lookup.")
    }
    public static func removable(_ owner: AppOwner, home: String) -> Bool {
        let registered = Set(NSWorkspace.shared.urlsForApplications(withBundleIdentifier: owner.identifier).map(\.path))
        return classification(owner, home: home, registered: registered).0 == .installedUser
    }
    public static func dataPaths(owner: AppOwner, installed: [AppOwner], home: String, systemLibrary: String = "/Library") -> [String] {
        OwnershipResolver(catalog: AppCatalog(owners: installed)).claims(for: owner, home: home, systemLibrary: systemLibrary)
            .filter { $0.confidence == .verifiedExclusive && $0.source != "bundle" }.flatMap(\.paths)
    }
    public static func ownedIdentifiers(_ owner: AppOwner) -> Set<String> { owner.identifiers }
    private static func canonicalPath(_ path: String) -> Bool {
        path.hasPrefix("/") && path != "/" && !path.hasSuffix("/") && !path.contains("//") && !path.utf8.contains(0)
            && !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
    }
    private static func parent(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else { return "/" }
        return String(path[..<slash])
    }
    public static func safeExisting(_ path: String) -> Bool {
        guard canonicalPath(path) else { return false }
        guard let resolved = realpath(path, nil) else { return false }
        defer { free(resolved) }
        return String(cString: resolved) == path
    }
    public static func normalizedPaths(_ paths: [String]) -> [String] {
        var selected = Set<String>()
        for path in Set(paths).sorted(by: { $0.count == $1.count ? $0 < $1 : $0.count < $1.count }) {
            guard canonicalPath(path) else { continue }
            var ancestor = parent(path)
            var covered = false
            while ancestor != "/" && !ancestor.isEmpty {
                if selected.contains(ancestor) { covered = true; break }
                ancestor = parent(ancestor)
            }
            if !covered { selected.insert(path) }
        }
        return selected.sorted()
    }
}
