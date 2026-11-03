import Foundation
import Darwin
import MacSpaceDiskMapPrivileged
import MacSpacePlatform

struct DiskApplication: Sendable {
    var owner: AppOwner
    var bytes: UInt64
    /// Only verified exclusive data targets, for compatibility with existing presentation code.
    var dataPaths: [String]
    var removable: Bool
    var metadataStamp: Date?
    var classification: AppClassification = .extraCopy
    var reason: String = ""
    var ownership: [DiskOwnershipClaim] = []
    var plan: AppRemovalPlan?
    var dataBytes: UInt64 = 0
    var ownershipBytes: [OwnershipConfidence: UInt64] = [:]
}
struct AppLeftover: Sendable {
    var identifier: String
    var path: String
    var bytes: UInt64
    var identity: AppFileIdentity?
    var choiceID: String {
        struct Target: Encodable { var path: String; var identity: AppFileIdentity? }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return "app-data:" + ((try? encoder.encode(Target(path: path, identity: identity))) ?? Data()).base64EncodedString()
    }
}
struct DiskApplications: Sendable {
    var apps: [DiskApplication] = []
    /// Unmatched is not proof that an app was removed. Only explicit, reviewed user-data choices may be freed.
    var reviewableLeftovers: [AppLeftover] = []
    var evidenceLimitations: [String] = [
        "Public registration lookup is bounded by discovered bundle identifiers; discovery is incomplete.",
        "Receipt manifests are historical, potentially incomplete evidence; receipt paths and helpers are never auto-deleted.",
        "Container metadata and signed groups remain reviewable until exclusivity can be established."
    ]
    var discoveryComplete = false
    var catalogRevision: UInt64?
    var catalogReadAt: Date = .distantPast
    var catalog = AppCatalog(owners: [])
    var receipts = AppReceiptCatalog()
    static let metadataRefreshInterval: TimeInterval = 60
    static func livePath(_ path: String) -> String {
        path.hasPrefix(DataVolume.path + "/") ? String(path.dropFirst(DataVolume.path.count)) : path
    }
    static func measuredPath(_ path: String, index: DiskIndex) -> String {
        if index.root == DataVolume.path, !path.hasPrefix(DataVolume.path + "/") { return DataVolume.path + path }
        return path
    }
    /// Allocated file bytes are included even when files are below the index's large-file threshold.
    /// Directory totals come from the snapshot; missing/unreadable directories remain unmeasured.
    static func measuredBytes(_ paths: [String], index: DiskIndex) -> UInt64 {
        var bytes: UInt64 = 0, files = Set<String>()
        let normalized = AppOwnership.normalizedPaths(paths)
        for path in normalized {
            if let directory = index.directories[measuredPath(path, index: index)] { bytes += directory.bytes; continue }
            if let measured = index.measuredOwnershipBytes?[measuredPath(path, index: index)] { bytes += measured; continue }
            var st = stat()
            guard AppOwnership.safeExisting(path), lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_flags & UInt32(SF_DATALESS) == 0 else { continue }
            let key = "\(st.st_dev):\(st.st_ino)"
            if files.insert(key).inserted { bytes += UInt64(max(0, st.st_blocks)) * 512 }
        }
        return bytes
    }
    static func read(_ index: DiskIndex, previous: DiskApplications?) -> DiskApplications {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var result: DiskApplications
        if let previous, previous.catalogRevision == index.catalogRevision, Date().timeIntervalSince(previous.catalogReadAt) < metadataRefreshInterval {
            // Byte revisions do not force signature verification or ownership discovery.
            result = previous
        } else {
            let candidates = (index.appPaths ?? index.directories.keys.filter { $0.hasSuffix(".app") && !$0.dropLast(4).contains(".app/") }).map(livePath)
            let catalog = AppOwnership.discover(home: home, candidates: candidates)
            let resolver = OwnershipResolver(catalog: catalog)
            let receipts = AppReceiptReader.read(previous: previous?.receipts)
            let receiptClaims = receipts.claims(owners: catalog.owners)
            result = DiskApplications()
            result.receipts = receipts
            result.catalogRevision = index.catalogRevision
            result.catalog = catalog; result.discoveryComplete = catalog.discoveryComplete; result.catalogReadAt = Date()
            for owner in catalog.owners {
                let classification = AppOwnership.classification(owner, home: home, registered: catalog.registeredPaths, candidates: catalog.owners)
                let ownership = resolver.claims(for: owner, home: home) + (receiptClaims[owner.path] ?? [])
                let plan = classification.0 == .installedUser ? resolver.plan(for: owner, home: home) : nil
                let dataPaths = ownership.filter { $0.confidence == .verifiedExclusive && $0.source != "bundle" }.flatMap(\.paths)
                let stamp = (try? FileManager.default.attributesOfItem(atPath: owner.path + "/Contents/Info.plist"))?[.modificationDate] as? Date
                result.apps.append(DiskApplication(owner: owner, bytes: 0, dataPaths: dataPaths, removable: plan != nil,
                    metadataStamp: stamp, classification: classification.0, reason: classification.1, ownership: ownership, plan: plan))
            }
            result.apps.sort { $0.owner.name.localizedStandardCompare($1.owner.name) == .orderedAscending }
        }
        result = result.remeasured(index)
        result.reviewableLeftovers = unmatchedData(index, apps: result.apps, knownIdentifiers: index.knownBundleIdentifiers ?? [], home: home)
        return result
    }
    static let reviewBases = ["Containers", "Application Support"]
    static func unmatchedData(_ index: DiskIndex, apps: [DiskApplication], knownIdentifiers: Set<String>, home: String) -> [AppLeftover] {
        let ids = knownIdentifiers.union(apps.flatMap { Array($0.owner.identifiers) + $0.owner.groups + Array($0.owner.helpers.keys) })
        let claimed = Set(apps.flatMap(\.ownership).flatMap(\.paths))
        var rows: [AppLeftover] = []
        for base in reviewBases {
            let folder = measuredPath(home + "/Library/" + base, index: index)
            for path in index.directories[folder]?.folders ?? [] {
                var id = (path as NSString).lastPathComponent
                if id.hasSuffix(".savedState") { id = String(id.dropLast(".savedState".count)) }
                let live = livePath(path)
                guard AppOwner.validIdentifier(id), !ids.contains(id), let node = index.directories[path], node.bytes > 0,
                      !claimed.contains(where: { index.contains(live, below: $0) || index.contains($0, below: live) }) else { continue }
                // Container metadata may name an identity different from the directory's name.
                if base == "Containers", let metadataID = NSDictionary(contentsOfFile: live + "/.com.apple.containermanagerd.metadata.plist")?["MCMMetadataIdentifier"] as? String,
                   ids.contains(metadataID) { continue }
                let identity = DiskUnmatchedRemoval.eligible(live, home: home) ? AppFileIdentity(path: live) : nil
                rows.append(AppLeftover(identifier: id, path: live, bytes: node.bytes, identity: identity))
            }
        }
        return rows.sorted { $0.bytes == $1.bytes ? $0.path < $1.path : $0.bytes > $1.bytes }
    }
    /// Updates allocation figures without rebuilding catalog/signing/ownership metadata.
    func remeasured(_ index: DiskIndex) -> DiskApplications {
        var result = self
        for n in result.apps.indices {
            result.apps[n].bytes = index.measuredOwnershipBytes?[Self.measuredPath(result.apps[n].owner.path, index: index)] ?? index.directories[Self.measuredPath(result.apps[n].owner.path, index: index)]?.bytes ?? 0
            let ownerPath = result.apps[n].owner.path
            let claims = result.apps[n].ownership.filter { $0.source != "bundle" }.map { claim in
                var claim = claim
                claim.paths = claim.paths.filter { $0 != ownerPath && !$0.hasPrefix(ownerPath + "/") }
                return claim
            }
            result.apps[n].dataBytes = Self.measuredBytes(claims.flatMap(\.paths), index: index)
            result.apps[n].ownershipBytes = Dictionary(grouping: claims, by: \.confidence).mapValues { Self.measuredBytes($0.flatMap(\.paths), index: index) }
        }
        for n in result.reviewableLeftovers.indices {
            result.reviewableLeftovers[n].bytes = Self.measuredBytes([result.reviewableLeftovers[n].path], index: index)
        }
        return result
    }

}
