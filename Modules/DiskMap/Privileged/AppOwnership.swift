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
    /// Installed launch services are additional exclusion evidence, never uninstall targets.
    public static func serviceIdentifiers(home: String) -> Set<String> {
        var result = Set<String>()
        for root in ["/System/Library/LaunchAgents", "/System/Library/LaunchDaemons", "/Library/LaunchAgents", "/Library/LaunchDaemons", home + "/Library/LaunchAgents"] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
            for name in names.prefix(8192) where name.hasSuffix(".plist") {
                let path = root + "/" + name
                var metadata = stat()
                guard lstat(path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
                      metadata.st_size <= 1_048_576, metadata.st_flags & UInt32(SF_DATALESS) == 0,
                      let info = NSDictionary(contentsOfFile: path), let label = info["Label"] as? String, AppOwner.validIdentifier(label) else { continue }
                let executable = info["Program"] as? String ?? (info["ProgramArguments"] as? [String])?.first
                guard let executable, executable.hasPrefix("/"), FileManager.default.fileExists(atPath: executable) else { continue }
                result.insert(label)
                let binary = (executable as NSString).lastPathComponent
                if !["sh", "bash", "zsh", "python", "python3", "node", "env"].contains(binary.lowercased()) { result.insert(binary) }
            }
        }
        return result
    }
    public static func hasRegisteredApplication(_ identifier: String) -> Bool {
        guard AppOwner.validIdentifier(identifier) else { return false }
        return NSWorkspace.shared.urlsForApplications(withBundleIdentifier: identifier).contains { safeExisting($0.path) }
    }
    public static func discover(home: String, candidates: [String] = [], progress: @Sendable (Double) -> Void = { _ in }) -> AppCatalog {
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
        let seeds = readOwners(paths.sorted(), progress: { progress(0.4 * $0) })
        if Task.isCancelled { return AppCatalog(owners: []) }
        let identifiers = Set(seeds.map(\.identifier))
        for (offset, id) in identifiers.sorted().enumerated() {
            if Task.isCancelled { return AppCatalog(owners: []) }
            let registeredPaths = autoreleasepool { NSWorkspace.shared.urlsForApplications(withBundleIdentifier: id).map(\.path) }
            for path in registeredPaths {
                if safeExisting(path) { paths.insert(path); registered.insert(path) }
            }
            progress(0.4 + 0.4 * Double(offset + 1) / Double(max(identifiers.count, 1)))
        }
        let prior = Dictionary(seeds.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let owners = readOwners(paths.sorted(), known: prior, progress: { progress(0.8 + 0.2 * $0) })
        if Task.isCancelled { return AppCatalog(owners: []) }
        progress(1)
        return AppCatalog(owners: owners, registeredPaths: registered)
    }

    /// Independent bundle metadata/signing reads overlap in bounded batches. Results and progress retain input order;
    /// cancellation is checked on the caller's task between batches, rather than on unrelated GCD worker threads.
    static func readOwners(_ paths: [String], known: [String: AppOwner] = [:],
                           read: @escaping @Sendable (String) -> AppOwner? = { AppOwner(path: $0, knownIdentifiers: []) },
                           progress: @Sendable (Double) -> Void = { _ in }) -> [AppOwner] {
        let values = LockedArray<AppOwner?>(repeating: nil, count: paths.count)
        for offset in stride(from: 0, to: paths.count, by: 4) {
            guard !Task.isCancelled else { return [] }
            let count = min(4, paths.count - offset)
            DispatchQueue.concurrentPerform(iterations: count) { index in
                let path = paths[offset + index]
                values.set(offset + index, autoreleasepool { known[path] ?? read(path) })
            }
            for index in 0..<count { progress(Double(offset + index + 1) / Double(paths.count)) }
        }
        return values.values.compactMap { $0 }
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
        if owner.path.contains(".app/") || [home + "/Library/", "/Library/", "/private/var/", "/var/"].contains(where: owner.path.hasPrefix) {
            return (.extraCopy, "Embedded helper or app-data copy; not a standalone application.")
        }
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
        FileReviewPolicy.isNormalizedAbsolutePath(path, allowTrailingSlash: false)
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
        let candidates = Set(paths.filter(canonicalPath))
        // Every valid candidate ancestor covers this path, whether that ancestor is itself covered
        // by an outer candidate or not. No length/grapheme sort is needed to discover the outermost set.
        return candidates.filter { path in
            var ancestor = parent(path)
            while ancestor != "/" && !ancestor.isEmpty {
                if candidates.contains(ancestor) { return false }
                ancestor = parent(ancestor)
            }
            return true
        }.sorted()
    }
}
