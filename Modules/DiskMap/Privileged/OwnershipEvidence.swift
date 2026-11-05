import Foundation
import Darwin

public enum OwnershipConfidence: String, Codable, Sendable { case verifiedExclusive, shared, inferred, unknown }
public struct DiskOwnershipClaim: Codable, Hashable, Sendable {
    public var paths: [String]
    public var ownerPaths: [String]
    public var confidence: OwnershipConfidence
    public var source: String
    public var reason: String
    public init(paths: [String], ownerPaths: [String], confidence: OwnershipConfidence, source: String, reason: String) {
        self.paths = paths.sorted(); self.ownerPaths = ownerPaths.sorted(); self.confidence = confidence; self.source = source; self.reason = reason
    }
}
public enum AppClassification: String, Codable, Sendable { case installedUser, protectedSystem, background, extraCopy, macSpaceLifecycle }
public struct AppFileIdentity: Codable, Equatable, Sendable {
    public var device: Int32
    public var inode: UInt64
    public var uid: UInt32
    public var modifiedSeconds: Int64
    public var modifiedNanos: Int64
    public init?(path: String) {
        var st = stat()
        guard AppOwnership.safeExisting(path), lstat(path, &st) == 0, st.st_flags & UInt32(SF_DATALESS) == 0 else { return nil }
        device = st.st_dev; inode = st.st_ino; uid = st.st_uid
        modifiedSeconds = Int64(st.st_mtimespec.tv_sec); modifiedNanos = Int64(st.st_mtimespec.tv_nsec)
    }
}
public struct AppRemovalTarget: Codable, Equatable, Sendable {
    public var path: String
    public var identity: AppFileIdentity
    public var evidence: DiskOwnershipClaim
}
public struct AppRemovalPlan: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var owner: AppOwner
    public var targets: [AppRemovalTarget]
    public var discoveryComplete: Bool
    /// Discovery hints only: the helper rereads these installations and never trusts supplied completeness.
    public var catalogCandidates: [String] = []
    public var startupItems: [AppStartupItem]? = nil
    public func encoded() throws -> String { String(decoding: try JSONEncoder().encode(self), as: UTF8.self) }
}
/// A bounded discovery result is not proof that no other installation exists.
public struct AppCatalog: Sendable {
    public var owners: [AppOwner]
    public var registeredPaths: Set<String>
    public var discoveryComplete: Bool
    public init(owners: [AppOwner], registeredPaths: Set<String> = [], discoveryComplete: Bool = false) {
        self.owners = owners; self.registeredPaths = registeredPaths; self.discoveryComplete = discoveryComplete
    }
}
public struct OwnershipResolver: Sendable {
    public let catalog: AppCatalog
    private var identifiers: [String: Set<String>] = [:]
    private var groups: [String: Set<String>] = [:]
    private var names: [String: Set<String>] = [:]
    private var ownerNames: [String: Set<String>] = [:]
    private var supportPaths: [String: String] = [:]
    private var supportOwners: [String: Set<String>] = [:]
    private var byHost: [String: [String]] = [:]
    private var embedded: [String: Set<String>] = [:]
    private var namedData: [String: [String]] = [:]
    public init(catalog: AppCatalog, byHostPreferences: [String] = [], embeddedIdentifiers: [String: Set<String>] = [:], availableDataPaths: [String] = []) {
        self.catalog = catalog
        for owner in catalog.owners {
            let parts = owner.identifier.split(separator: ".")
            let vendor = parts.count >= 3 ? parts.prefix(2).joined(separator: ".") : owner.identifier
            embedded[owner.path] = (embeddedIdentifiers[owner.path] ?? []).filter {
                $0 == owner.identifier || $0.hasPrefix(owner.identifier + ".")
                    || (!owner.identifier.hasPrefix("com.apple.") && $0.hasPrefix(vendor + "."))
            }
        }
        for path in availableDataPaths { namedData[Self.dataNameKey((path as NSString).lastPathComponent), default: []].append(path) }
        for path in byHostPreferences {
            let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            if path.hasSuffix(".plist"), let dot = name.lastIndex(of: "."), UUID(uuidString: String(name[name.index(after: dot)...])) != nil {
                byHost[String(name[..<dot]), default: []].append(path)
            }
        }
        for owner in catalog.owners {
            let ownerIDs = owner.identifiers.union(embedded[owner.path] ?? [])
            for id in ownerIDs { identifiers[id, default: []].insert(owner.path) }
            for group in owner.groups { groups[group, default: []].insert(owner.path) }
            // Bundle namespace/publisher components do not identify an app's support folder.
            // Keep the broader componentDataNames behavior for unmatched-data exclusions.
            let componentNames = Self.componentDataNames(Set((embedded[owner.path] ?? []).map {
                $0.split(separator: ".").dropFirst(2).joined(separator: ".")
            }))
            let dataNames = Self.dataNames(owner).union(componentNames); ownerNames[owner.path] = dataNames
            for name in dataNames { names[Self.dataNameKey(name), default: []].insert(owner.path) }
            if let relative = Self.declaredSupportPath(owner) {
                supportPaths[owner.path] = relative; supportOwners[relative, default: []].insert(owner.path)
            }
        }
    }
    public func claims(for owner: AppOwner, home: String, systemLibrary: String = "/Library") -> [DiskOwnershipClaim] {
        var result = [DiskOwnershipClaim(paths: [owner.path], ownerPaths: [owner.path], confidence: .verifiedExclusive, source: "bundle", reason: "This installation's bundle; other copies are separate installations.")]
        func append(_ path: String, id: String, owners: Set<String>, verified: Bool, source: String) {
            guard AppOwnership.safeExisting(path) else { return }
            if source == "displayNameConvention", Self.isPublisherDataRoot(path, owner: owner, home: home, systemLibrary: systemLibrary) { return }
            let confidence: OwnershipConfidence = owners.count > 1 ? .shared : verified && catalog.discoveryComplete ? .verifiedExclusive : verified ? .unknown : .inferred
            result.append(DiskOwnershipClaim(paths: [path], ownerPaths: Array(owners), confidence: confidence, source: source,
                reason: owners.count > 1 ? "Multiple known installations claim this data." : verified && !catalog.discoveryComplete ? "Metadata matches, but discovery cannot establish exclusive ownership." : verified ? "Exact metadata and complete catalog establish ownership." : "Conventional identifier path; ownership is not established."))
        }
        for library in [home + "/Library", systemLibrary] {
            for id in owner.identifiers.union(embedded[owner.path] ?? []) {
                let owners = identifiers[id] ?? [owner.path]
                for relative in ["Caches/" + id, "Application Support/" + id, "Application Scripts/" + id, "Preferences/" + id + ".plist", "Cookies/" + id + ".binarycookies", "HTTPStorages/" + id, "HTTPStorages/" + id + ".binarycookies", "WebKit/" + id, "Logs/" + id, "Saved Application State/" + id + ".savedState"] {
                    append(library + "/" + relative, id: id, owners: owners, verified: false, source: "identifierConvention")
                }
                for path in byHost[id] ?? [] where path.hasPrefix(library + "/Preferences/ByHost/") {
                    append(path, id: id, owners: owners, verified: false, source: "identifierConvention")
                }
                let path = library + "/Containers/" + id
                // Container metadata supplies identity, not permission to assume no other copy uses it.
                let metadata = NSDictionary(contentsOfFile: path + "/.com.apple.containermanagerd.metadata.plist")
                let matches = metadata?["MCMMetadataIdentifier"] as? String == id
                append(path, id: id, owners: owners, verified: matches && owner.signatureValid, source: matches ? "containerMetadata" : "identifierConvention")
            }
            for group in owner.groups {
                append(library + "/Group Containers/" + group, id: group, owners: groups[group] ?? [owner.path], verified: owner.signatureValid, source: "signedAppGroup")
                append(library + "/Application Scripts/" + group, id: group, owners: groups[group] ?? [owner.path], verified: false, source: "signedAppGroup")
            }
            for name in ownerNames[owner.path] ?? Self.dataNames(owner) {
                for base in ["Application Support", "Caches", "Logs"] {
                    append(library + "/" + base + "/" + name, id: owner.identifier, owners: names[Self.dataNameKey(name)] ?? [owner.path], verified: false, source: "displayNameConvention")
                }
                for path in namedData[Self.dataNameKey(name)] ?? [] where path.hasPrefix(library + "/") {
                    append(path, id: owner.identifier, owners: names[Self.dataNameKey(name)] ?? [owner.path], verified: false, source: "displayNameConvention")
                }
            }
            if let relative = supportPaths[owner.path] ?? Self.declaredSupportPath(owner) {
                let claimants = supportOwners[relative] ?? [owner.path]
                append(library + "/Application Support/" + relative, id: owner.identifier, owners: claimants, verified: false, source: "declaredSupportPath")
            }
        }
        // Receipt presence, display names and vendor-specific plist keys do not establish ownership.
        // Registered privileged helpers are reviewable only: stopping/unregistering them needs a lifecycle plan.
        for (id, requirement) in owner.helpers {
            let path = systemLibrary + "/PrivilegedHelperTools/" + id
            guard AppOwnership.safeExisting(path) else { continue }
            let claimants = catalog.owners.filter { $0.helpers[id] != nil }.map(\.path)
            result.append(DiskOwnershipClaim(paths: [path], ownerPaths: claimants, confidence: claimants.count > 1 ? .shared : .unknown,
                source: AppOwner.helperMatches(path, requirement: requirement, team: owner.team) ? "signedRegisteredHelper" : "unverifiedHelperDeclaration",
                reason: "Helper lifecycle removal is not supported; preserve for separate review."))
        }
        return result
    }
    public static func dataNames(_ owner: AppOwner) -> Set<String> {
        let info = NSDictionary(contentsOfFile: owner.path + "/Contents/Info.plist")
        let names = [owner.name, (owner.path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: ""), info?["CFBundleName"] as? String ?? ""]
        let generic: Set<String> = ["app", "application", "helper", "updater", "agent", "launcher"]
        return Set(names.filter { !$0.isEmpty && !$0.hasPrefix(".") && !$0.contains("/") && !$0.contains("\0") && !generic.contains($0.lowercased()) })
    }
    public static func dataNameKey(_ name: String) -> String {
        var parts = name.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if parts.count > 1, let last = parts.last, last.allSatisfy({ $0.isNumber || $0 == "." }) { parts.removeLast() }
        return parts.joined(separator: " ").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    public static func componentDataNames(_ identifiers: Set<String>) -> Set<String> {
        let generic: Set<String> = ["com", "org", "net", "framework", "helper", "renderer", "service", "plugin", "application", "extension", "extensions", "resources", "contents", "updater"]
        var names = Set<String>()
        for id in identifiers {
            for part in id.split(separator: ".") where part.count >= 3 && !generic.contains(part.lowercased()) && part.first?.isNumber != true {
                names.insert(dataNameKey(String(part)))
                for suffix in ["framework", "service", "plugin", "helper"] where part.lowercased().hasSuffix(suffix) && part.count > suffix.count + 3 {
                    names.insert(dataNameKey(String(part.dropLast(suffix.count))))
                }
            }
        }
        return names
    }
    /// A publisher-wide folder name is too broad to associate through display names alone.
    /// Explicit support-path declarations and signed metadata are evaluated independently.
    public static func isPublisherDataRoot(_ path: String, owner: AppOwner, home: String, systemLibrary: String = "/Library") -> Bool {
        let bases = [home + "/Library", systemLibrary].flatMap { library in
            ["Application Support", "Caches", "Logs"].map { library + "/" + $0 }
        }
        guard bases.contains((path as NSString).deletingLastPathComponent) else { return false }
        let publishers = Set(owner.identifiers.compactMap { identifier -> String? in
            let parts = identifier.split(separator: ".")
            guard parts.count >= 3 else { return nil }
            return dataNameKey(String(parts[1]))
        }).union(["apple"])
        let name = dataNameKey((path as NSString).lastPathComponent)
        guard publishers.contains(name) else { return false }
        // An exact product name is evidence in its own right, even if its identifier
        // repeats that word in the publisher namespace (for example org.example.product).
        let productNames = Set(dataNames(owner).map(dataNameKey))
        return name == "apple" || !productNames.contains(name)
    }
    private static func declaredSupportPath(_ owner: AppOwner) -> String? {
        guard let value = NSDictionary(contentsOfFile: owner.path + "/Contents/Info.plist")?["CrProductDirName"] as? String,
              !value.isEmpty, value.utf8.count < 512, !value.hasPrefix("/"), !value.contains("\0"),
              value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") }) else { return nil }
        return value
    }
    public func plan(for owner: AppOwner, home: String, systemLibrary: String = "/Library") -> AppRemovalPlan {
        let startup = AppStartupItems.discover(owner: owner, catalog: catalog, home: home, systemLibrary: systemLibrary)
        let claims = claims(for: owner, home: home, systemLibrary: systemLibrary).filter { $0.confidence == .verifiedExclusive }
            + startup.filter { !$0.path.hasPrefix(owner.path + "/") }.map {
                DiskOwnershipClaim(paths: [$0.path], ownerPaths: [owner.path], confidence: .verifiedExclusive, source: "startupItem", reason: "Startup executable belongs to this installation.")
            }
        let byPath = Dictionary(claims.flatMap { claim in claim.paths.map { ($0, claim) } }, uniquingKeysWith: { first, _ in first })
        let targets = AppOwnership.normalizedPaths(Array(byPath.keys)).compactMap { path -> AppRemovalTarget? in
            guard let identity = AppFileIdentity(path: path), let evidence = byPath[path] else { return nil }
            return AppRemovalTarget(path: path, identity: identity, evidence: evidence)
        }
        return AppRemovalPlan(owner: owner, targets: targets, discoveryComplete: catalog.discoveryComplete, catalogCandidates: Array(Set(catalog.owners.map(\.path) + [owner.path])).sorted(), startupItems: startup.isEmpty ? nil : startup)
    }
}
