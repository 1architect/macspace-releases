import AppKit
import Foundation
import MacSpaceDiskMapPrivileged
import MacSpacePlatform

struct DiskApplication: Sendable {
    var owner: AppOwner
    var bytes: UInt64
    var dataPaths: [String]
    var removable: Bool
    var metadataStamp: Date?
}
struct AppLeftover: Sendable {
    var identifier: String
    var paths: [String]
    var bytes: UInt64
}
struct DiskApplications: Sendable {
    var apps: [DiskApplication] = []
    var leftovers: [AppLeftover] = []
    static func livePath(_ path: String) -> String {
        path.hasPrefix(DataVolume.path + "/") ? String(path.dropFirst(DataVolume.path.count)) : path
    }
    static func measuredPath(_ path: String, index: DiskIndex) -> String {
        if index.root == DataVolume.path, !path.hasPrefix(DataVolume.path + "/") { return DataVolume.path + path }
        return path
    }
    static func read(_ index: DiskIndex, previous: DiskApplications?) -> DiskApplications {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let appPaths = index.directories.keys.filter { path in
            path.hasSuffix(".app") && !path.dropLast(4).contains(".app/") && !path.contains("/.Trash/")
        }.map(livePath)
        // The sealed system Applications folder lives outside the mapped Data volume.
        var nestedIDs: [String: Set<String>] = [:]
        for node in index.directories.values {
            guard let id = node.bundleIdentifier, let end = node.path.range(of: ".app/")?.lowerBound else { continue }
            let app = String(node.path[..<end]) + ".app"
            nestedIDs[livePath(app), default: []].insert(id)
        }
        var paths = Set(appPaths)
        if index.root == DataVolume.path, let iterator = FileManager.default.enumerator(atPath: "/System/Applications") {
            for case let name as String in iterator where name.hasSuffix(".app") { paths.insert("/System/Applications/" + name); iterator.skipDescendants() }
        }
        var stamps: [String: Date] = [:]
        let owners = paths.compactMap { path -> AppOwner? in
            autoreleasepool {
            let stamp = (try? FileManager.default.attributesOfItem(atPath: path + "/Contents/Info.plist"))?[.modificationDate] as? Date
            stamps[path] = stamp
            if let old = previous?.apps.first(where: { $0.owner.path == path }), old.metadataStamp == stamp { return old.owner }
            // The disk walk already collected embedded bundle identities. An empty set must not
            // fall back to enumerating the application's entire Contents tree a second time.
            return AppOwner(path: path, knownIdentifiers: nestedIDs[path] ?? [])
            }
        }
        let ids = Set(owners.flatMap { $0.identifiers })
        var result = DiskApplications()
        for owner in owners {
            let dataPaths = autoreleasepool { AppOwnership.dataPaths(owner: owner, installed: owners, home: home) }
            let bytes = index.directories[measuredPath(owner.path, index: index)]?.bytes ?? 0
            result.apps.append(DiskApplication(owner: owner, bytes: bytes, dataPaths: dataPaths, removable: AppOwnership.removable(owner, home: home), metadataStamp: stamps[owner.path]))
        }
        result.apps.sort { $0.owner.name.localizedStandardCompare($1.owner.name) == .orderedAscending }
        let bases = ["Caches", "Containers", "Application Support", "HTTPStorages", "WebKit", "Saved Application State"]
        var grouped: [String: [String]] = [:]
        for base in bases {
            let folder = measuredPath(home + "/Library/" + base, index: index)
            for path in index.directories[folder]?.folders ?? [] {
                var id = (path as NSString).lastPathComponent
                if id.hasSuffix(".savedState") { id = String(id.dropLast(".savedState".count)) }
                guard AppOwner.validIdentifier(id), !id.hasPrefix("com.apple."), !id.hasPrefix("com.macspace"), !ids.contains(id),
                      NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map({ FileManager.default.fileExists(atPath: $0.path) }) != true else { continue }
                grouped[id, default: []].append(livePath(path))
            }
        }
        for (id, paths) in grouped {
            result.leftovers.append(AppLeftover(identifier: id, paths: paths, bytes: paths.reduce(0) { $0 + (index.directories[measuredPath($1, index: index)]?.bytes ?? 0) }))
        }
        return result
    }
}
