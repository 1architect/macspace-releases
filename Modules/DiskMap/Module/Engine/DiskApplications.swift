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
    var paths: [String]
    var bytes: UInt64
}
struct DiskApplications: Sendable {
    var apps: [DiskApplication] = []
    /// Destructive legacy leftovers stay empty: absence from an incomplete catalog is not orphan evidence.
    var leftovers: [AppLeftover] = []
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
        let directoryRoots = normalized.filter { index.directories[measuredPath($0, index: index)] != nil }.map { measuredPath($0, index: index) }
        for path in normalized {
            if let directory = index.directories[measuredPath(path, index: index)] { bytes += directory.bytes; continue }
            if let measured = index.measuredOwnershipBytes?[measuredPath(path, index: index)] { bytes += measured; continue }
            var st = stat()
            guard AppOwnership.safeExisting(path), lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_flags & UInt32(SF_DATALESS) == 0 else { continue }
            let key = "\(st.st_dev):\(st.st_ino)"
            if let canonical = index.hardlinks[key]?.min(by: { $0.path < $1.path }), directoryRoots.contains(where: { index.contains(canonical.path, below: $0) }) { continue }
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
        // Unknown data remains reviewable, never handed to the legacy destructive leftovers action.
        let ids = Set(result.catalog.owners.flatMap(\.identifiers))
        var grouped: [String: [String]] = [:]
        for base in ["Caches", "Containers", "Application Support", "HTTPStorages", "WebKit", "Saved Application State"] {
            let folder = measuredPath(home + "/Library/" + base, index: index)
            for path in index.directories[folder]?.folders ?? [] {
                var id = (path as NSString).lastPathComponent
                if id.hasSuffix(".savedState") { id = String(id.dropLast(".savedState".count)) }
                guard AppOwner.validIdentifier(id), !ids.contains(id) else { continue }
                grouped[id, default: []].append(livePath(path))
            }
        }
        result.reviewableLeftovers = grouped.sorted { $0.key < $1.key }.map { AppLeftover(identifier: $0.key, paths: $0.value.sorted(), bytes: measuredBytes($0.value, index: index)) }
        return result
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
            result.reviewableLeftovers[n].bytes = Self.measuredBytes(result.reviewableLeftovers[n].paths, index: index)
        }
        return result
    }

}
