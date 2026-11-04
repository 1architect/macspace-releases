import Foundation
import Darwin
import MacSpaceDiskMapPrivileged
import MacSpacePlatform
import MacSpaceSdk

struct DiskApplication: Sendable {
    var owner: AppOwner
    var bytes: UInt64
    var measurementComplete = false
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
    var fileIdentity: FileReviewIdentity?
    var choiceID: String {
        struct Target: Encodable { var path: String; var identity: AppFileIdentity?; var fileIdentity: FileReviewIdentity? }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return "app-data:" + ((try? encoder.encode(Target(path: path, identity: identity, fileIdentity: fileIdentity))) ?? Data()).base64EncodedString()
    }
}
struct DiskApplications: Sendable {
    private struct FileMeasurement: Sendable { var bytes: UInt64; var identity: String? }
    private var measurementRevision: UInt64?
    private var measurementRoot: String?
    private var fileMeasurements: [String: FileMeasurement] = [:]
    var apps: [DiskApplication] = []
    /// Unmatched is not proof that an app was removed. Only explicit, reviewed user-data choices may be freed.
    var reviewableLeftovers: [AppLeftover] = []
    var evidenceLimitations: [String] = [
        "Public registration lookup is bounded by discovered bundle identifiers; discovery is incomplete.",
        "Receipt manifests are historical, potentially incomplete evidence; receipt paths and helpers are never auto-deleted.",
        "Container metadata and signed groups remain reviewable until exclusivity can be established."
    ]
    var measurementsComplete = false
    var discoveryComplete = false
    var catalogRevision: UInt64?
    var catalogReadAt: Date = .distantPast
    var catalog = AppCatalog(owners: [])
    var receipts = AppReceiptCatalog()
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
        var measurements: [String: FileMeasurement] = [:]
        return measuredBytes(paths, index: index, measurements: &measurements)
    }
    private static func measuredBytes(_ paths: [String], index: DiskIndex, measurements: inout [String: FileMeasurement]) -> UInt64 {
        var bytes: UInt64 = 0, files = Set<String>()
        for path in AppOwnership.normalizedPaths(paths) {
            if let directory = index.directories[measuredPath(path, index: index)] { bytes += directory.bytes; continue }
            if let measured = index.measuredOwnershipBytes?[measuredPath(path, index: index)] { bytes += measured; continue }
            let measurement: FileMeasurement
            if let cached = measurements[path] { measurement = cached }
            else {
                var st = stat()
                if AppOwnership.safeExisting(path), lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_flags & UInt32(SF_DATALESS) == 0 {
                    measurement = FileMeasurement(bytes: UInt64(max(0, st.st_blocks)) * 512, identity: "\(st.st_dev):\(st.st_ino)")
                } else { measurement = FileMeasurement(bytes: 0, identity: nil) }
                if measurements.count < 65_536 { measurements[path] = measurement }
            }
            if let identity = measurement.identity, files.insert(identity).inserted { bytes += measurement.bytes }
        }
        return bytes
    }
    static func read(_ index: DiskIndex, previous: DiskApplications?, progress: @escaping LoadProgressSink = { _ in }) -> DiskApplications {
        guard index.inventoryAuthoritative == true || index.appPaths != nil && index.knownBundleIdentifiers != nil else { return previous ?? DiskApplications() }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var result: DiskApplications
        if let previous, previous.catalogRevision == index.catalogRevision {
            // Byte revisions do not force signature verification or ownership discovery.
            result = previous
        } else {
            let candidates = (index.appPaths ?? index.directories.keys.filter { $0.hasSuffix(".app") && !$0.dropLast(4).contains(".app/") }).map(livePath)
            let catalog = AppOwnership.discover(home: home, candidates: candidates, progress: { progress(0.25 * $0) })
            let byHost = home + "/Library/Preferences/ByHost"
            let preferences = (try? FileManager.default.contentsOfDirectory(atPath: byHost)) ?? []
            let dataPaths = [home + "/Library", "/Library"].flatMap { library in
                ["Application Support", "Caches", "Logs"].flatMap { base -> [String] in
                    let folder = library + "/" + base
                    return ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).prefix(8192).map { folder + "/" + $0 }
                }
            }
            let resolver = OwnershipResolver(catalog: catalog, byHostPreferences: preferences.prefix(8192).map { byHost + "/" + $0 },
                embeddedIdentifiers: index.appBundleIdentifiers ?? [:], availableDataPaths: dataPaths)
            let receipts = AppReceiptReader.read(previous: previous?.receipts)
            progress(0.4)
            let receiptClaims = receipts.claims(owners: catalog.owners)
            result = DiskApplications()
            result.receipts = receipts
            result.catalogRevision = index.catalogRevision
            result.catalog = catalog; result.discoveryComplete = catalog.discoveryComplete; result.catalogReadAt = Date()
            for owner in catalog.owners {
                if Task.isCancelled { return previous ?? DiskApplications() }
                let classification = AppOwnership.classification(owner, home: home, registered: catalog.registeredPaths, candidates: catalog.owners)
                let ownership = resolver.claims(for: owner, home: home) + (receiptClaims[owner.path] ?? [])
                let plan = classification.0 == .installedUser ? resolver.plan(for: owner, home: home) : nil
                let dataPaths = ownership.filter { $0.confidence == .verifiedExclusive && $0.source != "bundle" }.flatMap(\.paths)
                let stamp = (try? FileManager.default.attributesOfItem(atPath: owner.path + "/Contents/Info.plist"))?[.modificationDate] as? Date
                result.apps.append(DiskApplication(owner: owner, bytes: 0, dataPaths: dataPaths, removable: plan != nil,
                    metadataStamp: stamp, classification: classification.0, reason: classification.1, ownership: ownership, plan: plan))
                progress(0.4 + 0.5 * Double(result.apps.count) / Double(max(catalog.owners.count, 1)))
            }
            result.apps.sort { $0.owner.name.localizedStandardCompare($1.owner.name) == .orderedAscending }
        }
        result = result.remeasured(index, progress: { progress(0.9 + 0.06 * $0) })
        let measuredBases = reviewBases.map { measuredPath(home + "/Library/" + $0, index: index) }
        result.measurementsComplete = measuredBases.allSatisfy {
            if index.directories[$0]?.readable == true { return true }
            var info = stat()
            return lstat(Self.livePath($0), &info) != 0 && (errno == ENOENT || errno == ENOTDIR)
        }
        // Refilter against today's installed catalog even if a different Library scope is unreadable.
        // Retaining the previous candidate list can offer newly installed apps' data for removal.
        var fileScopesComplete = true
        let known = (index.knownBundleIdentifiers ?? []).union(AppOwnership.serviceIdentifiers(home: home))
        result.reviewableLeftovers = unmatchedData(index, apps: result.apps, knownIdentifiers: known, home: home, unreadable: { _ in fileScopesComplete = false })
        result.measurementsComplete = result.measurementsComplete && fileScopesComplete
        progress(1)
        return result
    }
    static let reviewBases = AppDataReviewPolicy.directoryBases
    static func unmatchedData(_ index: DiskIndex, apps: [DiskApplication], knownIdentifiers: Set<String>, home: String, unreadable: ((String) -> Void)? = nil) -> [AppLeftover] {
        let ids = knownIdentifiers.union(apps.flatMap { Array($0.owner.identifiers) + $0.owner.groups + Array($0.owner.helpers.keys) })
        var identifierPrefixes = ids
        for identifier in ids {
            var prefix = identifier
            while let dot = prefix.lastIndex(of: ".") {
                prefix = String(prefix[..<dot]); identifierPrefixes.insert(prefix)
            }
        }
        let names = Set(apps.flatMap { OwnershipResolver.dataNames($0.owner) }.map(OwnershipResolver.dataNameKey))
            .union(OwnershipResolver.componentDataNames(ids))
        // Vendor roots and sibling helper IDs are not evidence of abandoned data while another
        // product from that vendor is installed. This exclusion never authorizes a removal target.
        let genericVendors: Set<String> = ["github", "gitlab", "sourceforge", "electron", "todesktop", "example"]
        let vendorNamespaces = Set(apps.flatMap { $0.owner.identifiers }.compactMap { identifier -> String? in
            let parts = identifier.lowercased().split(separator: ".")
            guard parts.count >= 3, !genericVendors.contains(String(parts[1])) else { return nil }
            return parts.prefix(2).joined(separator: ".")
        })
        let vendorNames = Set(vendorNamespaces.compactMap { $0.split(separator: ".").last.map(String.init) })
        let installedTeams = Set(apps.compactMap { $0.owner.team })
        let claimed = Set(apps.flatMap(\.ownership).flatMap(\.paths))
        var rows: [AppLeftover] = []
        func identifierMatch(_ value: String) -> Bool {
            if identifierPrefixes.contains(value) { return true }
            var prefix = value
            while let dot = prefix.lastIndex(of: ".") {
                prefix = String(prefix[..<dot])
                if ids.contains(prefix) { return true }
            }
            return false
        }
        func matched(_ id: String, path: String) -> Bool {
            id.lowercased().hasPrefix("com.apple.") || id.lowercased().contains(".com.apple.") || id.lowercased() == "apple"
                || names.contains(OwnershipResolver.dataNameKey(id))
                || vendorNames.contains(id.lowercased()) || vendorNamespaces.contains(id.lowercased().split(separator: ".").prefix(2).joined(separator: "."))
                || installedTeams.contains(String(id.split(separator: ".").first ?? ""))
                || identifierMatch(id)
                || claimed.contains(where: { index.contains(path, below: $0) || index.contains($0, below: path) })
        }
        for base in reviewBases {
            let folder = measuredPath(home + "/Library/" + base, index: index)
            guard index.directories[folder]?.readable == true else { continue }
            for path in index.directories[folder]?.folders ?? [] {
                var id = (path as NSString).lastPathComponent
                if id.hasSuffix(".savedState") { id = String(id.dropLast(".savedState".count)) }
                let live = livePath(path)
                guard !id.hasPrefix("."), !matched(id, path: live), AppDataReviewPolicy.includesDirectory(live, home: home),
                      let node = index.directories[path], node.readable, node.bytes > 0 else { continue }
                // Container metadata may name an identity different from the directory's name.
                if base == "Containers", let metadataID = NSDictionary(contentsOfFile: live + "/.com.apple.containermanagerd.metadata.plist")?["MCMMetadataIdentifier"] as? String {
                    if matched(metadataID, path: live) || AppOwnership.hasRegisteredApplication(metadataID) { continue }
                    if AppOwner.validIdentifier(metadataID) { id = metadataID }
                }
                if AppOwner.validIdentifier(id), AppOwnership.hasRegisteredApplication(id) { continue }
                let identity = DiskUnmatchedRemoval.eligible(live, home: home) ? AppFileIdentity(path: live) : nil
                rows.append(AppLeftover(identifier: id, path: live, bytes: node.bytes, identity: identity))
            }
        }
        for base in AppDataReviewPolicy.fileBases {
            let parent = home + "/Library/" + base
            var info = stat()
            if lstat(parent, &info) != 0 {
                if errno != ENOENT && errno != ENOTDIR { unreadable?(parent) }
                continue
            }
            guard info.st_mode & S_IFMT == S_IFDIR, info.st_flags & UInt32(SF_DATALESS) == 0 else { unreadable?(parent); continue }
            let first = rows.count
            let complete = DirectoryWalk.entries(at: parent) { name, entry in
                guard entry.isRegularFile, !entry.isDataless, entry.ownerUID == getuid(), entry.allocatedBytes > 0 else { return }
                let path = parent + "/" + name
                guard AppDataReviewPolicy.includesFile(path, home: home) else { return }
                var id = (name as NSString).deletingPathExtension
                if base == "Preferences/ByHost", let dot = id.lastIndex(of: "."), UUID(uuidString: String(id[id.index(after: dot)...])) != nil { id = String(id[..<dot]) }
                guard AppOwner.validIdentifier(id), !matched(id, path: path), !AppOwnership.hasRegisteredApplication(id),
                      let target = DiskAppDataRemoval.target(path, home: home), target.fileIdentity != nil else { return }
                rows.append(AppLeftover(identifier: id, path: path, bytes: entry.allocatedBytes, identity: target.identity, fileIdentity: target.fileIdentity))
            }
            if !complete { rows.removeSubrange(first...); unreadable?(parent) }
        }
        return rows.sorted { $0.bytes == $1.bytes ? $0.path < $1.path : $0.bytes > $1.bytes }
    }
    /// Updates allocation figures without rebuilding catalog/signing/ownership metadata.
    func remeasured(_ index: DiskIndex, progress: LoadProgressSink = { _ in }) -> DiskApplications {
        guard index.inventoryAuthoritative == true || index.appPaths != nil else { return self }
        var result = self
        var measurements = measurementRevision == index.revision && measurementRoot == index.root ? fileMeasurements : [:]
        for n in result.apps.indices {
            result.apps[n].bytes = index.measuredOwnershipBytes?[Self.measuredPath(result.apps[n].owner.path, index: index)] ?? index.directories[Self.measuredPath(result.apps[n].owner.path, index: index)]?.bytes ?? result.apps[n].bytes
            let ownerPath = result.apps[n].owner.path
            let measuredPath = Self.measuredPath(ownerPath, index: index)
            result.apps[n].measurementComplete = index.measuredOwnershipBytes?[measuredPath] != nil || index.directories[measuredPath]?.readable == true
            let claims = result.apps[n].ownership.filter { $0.source != "bundle" }.map { claim in
                var claim = claim
                claim.paths = claim.paths.filter { $0 != ownerPath && !$0.hasPrefix(ownerPath + "/") }
                return claim
            }
            result.apps[n].dataBytes = Self.measuredBytes(claims.flatMap(\.paths), index: index, measurements: &measurements)
            result.apps[n].ownershipBytes = Dictionary(grouping: claims, by: \.confidence).mapValues { Self.measuredBytes($0.flatMap(\.paths), index: index, measurements: &measurements) }
            progress(Double(n + 1) / Double(max(result.apps.count, 1)))
        }
        for n in result.reviewableLeftovers.indices {
            result.reviewableLeftovers[n].bytes = Self.measuredBytes([result.reviewableLeftovers[n].path], index: index, measurements: &measurements)
        }
        result.fileMeasurements = measurements
        result.measurementRevision = index.revision; result.measurementRoot = index.root
        return result
    }

}
