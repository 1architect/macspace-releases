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
    public init(catalog: AppCatalog) {
        self.catalog = catalog
        for owner in catalog.owners {
            for id in owner.identifiers { identifiers[id, default: []].insert(owner.path) }
            for group in owner.groups { groups[group, default: []].insert(owner.path) }
        }
    }
    public func claims(for owner: AppOwner, home: String, systemLibrary: String = "/Library") -> [DiskOwnershipClaim] {
        var result = [DiskOwnershipClaim(paths: [owner.path], ownerPaths: [owner.path], confidence: .verifiedExclusive, source: "bundle", reason: "This installation's bundle; other copies are separate installations.")]
        func append(_ path: String, id: String, owners: Set<String>, verified: Bool, source: String) {
            guard AppOwnership.safeExisting(path) else { return }
            let confidence: OwnershipConfidence = owners.count > 1 ? .shared : verified && catalog.discoveryComplete ? .verifiedExclusive : verified ? .unknown : .inferred
            result.append(DiskOwnershipClaim(paths: [path], ownerPaths: Array(owners), confidence: confidence, source: source,
                reason: owners.count > 1 ? "Multiple known installations claim this data." : verified && !catalog.discoveryComplete ? "Metadata matches, but discovery cannot establish exclusive ownership." : verified ? "Exact metadata and complete catalog establish ownership." : "Conventional identifier path; ownership is not established."))
        }
        for library in [home + "/Library", systemLibrary] {
            for id in owner.identifiers {
                let owners = identifiers[id] ?? [owner.path]
                for relative in ["Caches/" + id, "Application Support/" + id, "Preferences/" + id + ".plist", "HTTPStorages/" + id, "WebKit/" + id, "Logs/" + id, "Saved Application State/" + id + ".savedState"] {
                    append(library + "/" + relative, id: id, owners: owners, verified: false, source: "identifierConvention")
                }
                let path = library + "/Containers/" + id
                // Container metadata supplies identity, not permission to assume no other copy uses it.
                let metadata = NSDictionary(contentsOfFile: path + "/.com.apple.containermanagerd.metadata.plist")
                let matches = metadata?["MCMMetadataIdentifier"] as? String == id
                append(path, id: id, owners: owners, verified: matches && owner.signatureValid, source: matches ? "containerMetadata" : "identifierConvention")
            }
            for group in owner.groups {
                append(library + "/Group Containers/" + group, id: group, owners: groups[group] ?? [owner.path], verified: owner.signatureValid, source: "signedAppGroup")
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
    public func plan(for owner: AppOwner, home: String, systemLibrary: String = "/Library") -> AppRemovalPlan {
        let claims = claims(for: owner, home: home, systemLibrary: systemLibrary).filter { $0.confidence == .verifiedExclusive }
        let byPath = Dictionary(claims.flatMap { claim in claim.paths.map { ($0, claim) } }, uniquingKeysWith: { first, _ in first })
        let targets = AppOwnership.normalizedPaths(Array(byPath.keys)).compactMap { path -> AppRemovalTarget? in
            guard let identity = AppFileIdentity(path: path), let evidence = byPath[path] else { return nil }
            return AppRemovalTarget(path: path, identity: identity, evidence: evidence)
        }
        return AppRemovalPlan(owner: owner, targets: targets, discoveryComplete: catalog.discoveryComplete, catalogCandidates: Array(Set(catalog.owners.map(\.path) + [owner.path])).sorted())
    }
}
