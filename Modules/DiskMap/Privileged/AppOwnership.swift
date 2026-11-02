import Foundation
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
    public var supportNames: Set<String>
    public var profileDirectory: String?
    public init?(path: String, knownIdentifiers: Set<String>? = nil) {
        let url = URL(fileURLWithPath: path)
        var metadata = stat()
        guard lstat(path, &metadata) == 0, metadata.st_flags & UInt32(SF_DATALESS) == 0,
              lstat(path + "/Contents", &metadata) == 0, metadata.st_flags & UInt32(SF_DATALESS) == 0,
              lstat(path + "/Contents/Info.plist", &metadata) == 0, metadata.st_flags & UInt32(SF_DATALESS) == 0 else { return nil }
        guard url.pathExtension == "app", let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) as? [String: Any],
              let identifier = info["CFBundleIdentifier"] as? String, Self.validIdentifier(identifier) else { return nil }
        self.path = path; self.identifier = identifier
        name = info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? url.deletingPathExtension().lastPathComponent
        supportNames = Set([info["CFBundleName"] as? String, info["CFBundleDisplayName"] as? String, url.deletingPathExtension().lastPathComponent].compactMap { $0 })
        if let profile = info["CrProductDirName"] as? String {
            let parts = profile.split(separator: "/", omittingEmptySubsequences: false)
            profileDirectory = !profile.hasPrefix("/") && !parts.isEmpty && parts.count <= 4
                && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." } ? profile : nil
        } else { profileDirectory = nil }
        let signing = Self.signing(path)
        team = signing?[kSecCodeInfoTeamIdentifier as String] as? String
        let entitlements = signing?[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        groups = (entitlements?["com.apple.security.application-groups"] as? [String] ?? []).filter(Self.validIdentifier)
        identifiers = Set((knownIdentifiers ?? []).filter { Self.validIdentifier($0) && !$0.hasPrefix("com.apple.") }).union([identifier])
        if knownIdentifiers == nil, let iterator = FileManager.default.enumerator(atPath: path + "/Contents") {
            for case let relative as String in iterator {
                var infoStat = stat()
                guard lstat(path + "/Contents/" + relative, &infoStat) == 0 else { continue }
                if infoStat.st_flags & UInt32(SF_DATALESS) != 0 { iterator.skipDescendants(); continue }
                guard relative.hasSuffix("/Info.plist") else { continue }
                let info = NSDictionary(contentsOfFile: path + "/Contents/" + relative)
                if let id = info?["CFBundleIdentifier"] as? String, Self.validIdentifier(id), !id.hasPrefix("com.apple.") { identifiers.insert(id) }
            }
        }
        helpers = (info["SMPrivilegedExecutables"] as? [String: String] ?? [:]).filter { Self.validIdentifier($0.key) }
    }
    public static func validIdentifier(_ id: String) -> Bool {
        id.contains(".") && id.count < 240 && id.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]+$", options: .regularExpression) != nil
    }
    public static func signing(_ path: String) -> [String: Any]? {
        var code: SecStaticCode?; var info: CFDictionary?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess else { return nil }
        return info as? [String: Any]
    }
}

public enum AppOwnership {
    public static func installed(home: String) -> [AppOwner] {
        var result: [AppOwner] = []
        for root in ["/Applications", "/System/Applications", home + "/Applications"] {
            var info = stat()
            guard lstat(root, &info) == 0, info.st_flags & UInt32(SF_DATALESS) == 0 else { continue }
            guard let iterator = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in iterator {
                var info = stat()
                if lstat(url.path, &info) == 0, info.st_flags & UInt32(SF_DATALESS) != 0 { iterator.skipDescendants(); continue }
                if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { iterator.skipDescendants(); continue }
                if url.pathExtension == "app", let owner = AppOwner(path: url.path) { result.append(owner); iterator.skipDescendants() }
            }
        }
        return result
    }
    public static func removable(_ owner: AppOwner, home: String) -> Bool {
        let path = owner.path
        return !owner.identifier.hasPrefix("com.apple.") && !owner.identifier.hasPrefix("com.macspace")
            && (path.hasPrefix("/Applications/") || path.hasPrefix(home + "/"))
            && path == URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }
    /// Exact identifier-owned data plus unambiguous app-name support folders. Shared signed app groups stay if any app claims them.
    public static func dataPaths(owner: AppOwner, installed: [AppOwner], home: String, systemLibrary: String = "/Library") -> [String] {
        let others = installed.filter { $0.path != owner.path }
        let ids = ownedIdentifiers(owner).subtracting(others.flatMap { ownedIdentifiers($0) })
        var paths: [String] = []
        for library in [home + "/Library", systemLibrary] {
            for id in ids {
                for relative in ["Application Support/" + id, "Caches/" + id, "Preferences/" + id + ".plist", "Containers/" + id,
                                 "Saved Application State/" + id + ".savedState", "HTTPStorages/" + id, "WebKit/" + id, "Logs/" + id, "Cookies/" + id + ".binarycookies"] {
                    paths.append(library + "/" + relative)
                }
            }
            // Chromium-based apps declare their actual product/profile directory in Info.plist.
            // Its vendor parent can be shared, so only the product directory is owned by this app.
            if let profile = owner.profileDirectory, !others.contains(where: {
                $0.identifier == owner.identifier || $0.profileDirectory.map { $0 == profile || $0.hasPrefix(profile + "/") || profile.hasPrefix($0 + "/") } == true
            }) {
                paths.append(library + "/Application Support/" + profile)
                paths.append(library + "/Caches/" + profile)
            }
            for name in owner.supportNames where !others.contains(where: {
                $0.supportNames.contains(name) || $0.profileDirectory.map { $0 == name || $0.hasPrefix(name + "/") } == true
            })
                && !name.isEmpty && !name.contains("/") && name != "." && name != ".." {
                paths.append(library + "/Application Support/" + name)
                paths.append(library + "/Caches/" + name)
                paths.append(library + "/Logs/" + name)
            }
            for group in owner.groups where !others.contains(where: { $0.groups.contains(group) }) { paths.append(library + "/Group Containers/" + group) }
            for id in ids {
                for kind in ["LaunchAgents", "LaunchDaemons"] {
                    let path = library + "/" + kind + "/" + id + ".plist"
                    if let info = NSDictionary(contentsOfFile: path), info["Label"] as? String == id,
                       let program = info["Program"] as? String ?? (info["ProgramArguments"] as? [String])?.first,
                       program.hasPrefix(owner.path + "/") || paths.contains(where: { program == $0 || program.hasPrefix($0 + "/") }) { paths.append(path) }
                }
            }
            // ByHost preferences have a machine identifier suffix, not a fuzzy application-name match.
            let byHost = library + "/Preferences/ByHost"
            for name in (try? FileManager.default.contentsOfDirectory(atPath: byHost)) ?? [] where ids.contains(where: { name.hasPrefix($0 + ".") && name.hasSuffix(".plist") }) { paths.append(byHost + "/" + name) }
        }
        for (id, requirement) in owner.helpers where !others.contains(where: { $0.helpers[id] != nil }) {
            let helper = "/Library/PrivilegedHelperTools/" + id
            var code: SecStaticCode?; var rule: SecRequirement?
            if owner.team != nil, AppOwner.signing(helper)?[kSecCodeInfoTeamIdentifier as String] as? String == owner.team,
               SecStaticCodeCreateWithPath(URL(fileURLWithPath: helper) as CFURL, [], &code) == errSecSuccess,
               SecRequirementCreateWithString(requirement as CFString, [], &rule) == errSecSuccess,
               let code, let rule, SecStaticCodeCheckValidity(code, [], rule) == errSecSuccess {
                paths += [helper, "/Library/LaunchDaemons/" + id + ".plist"]
            }
        }
        return Array(Set(paths)).filter { safeExisting($0) }.sorted()
    }
    public static func ownedIdentifiers(_ owner: AppOwner) -> Set<String> { owner.identifiers }
    public static func safeExisting(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path) && URL(fileURLWithPath: path).resolvingSymlinksInPath().path == path
    }
}
