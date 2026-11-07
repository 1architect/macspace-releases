import Foundation
import Darwin
import MacSpacePlatform

/// A completed index is retained; interrupted and retired generations are disposable cache data.
enum DiskCacheRetention {
    /// Select only this index's known cache artifacts. Unrelated files and recovery/history data are retained.
    static func removeOwnedArtifacts(base: URL, home: String) throws {
        let folder = base.deletingLastPathComponent()
        var directory = stat()
        if lstat(folder.path, &directory) != 0 {
            if errno == ENOENT { return }
            throw CocoaError(.fileReadNoPermission)
        }
        guard directory.st_mode & S_IFMT == S_IFDIR, directory.st_uid == getuid() else { throw CocoaError(.fileWriteNoPermission) }
        let root = try ReviewedDirectoryRemoval.CleanupRoot(folder.path)
        var targets: [ReviewedDirectoryRemoval.Target] = []
        for target in try root.targets() {
            let file = URL(fileURLWithPath: target.path)
            let name = file.lastPathComponent
            let stem: String
            if name.hasSuffix("-journal") { stem = String(name.dropLast(8)) }
            else if name.hasSuffix("-wal") || name.hasSuffix("-shm") { stem = String(name.dropLast(4)) }
            else { stem = name }
            let suffix = stem.hasPrefix(base.lastPathComponent + ".") ? String(stem.dropFirst(base.lastPathComponent.count + 1)) : ""
            guard [base.lastPathComponent, base.lastPathComponent + ".current", base.lastPathComponent + ".receipts.json",
                   base.lastPathComponent + ".selection"].contains(stem) || UUID(uuidString: suffix) != nil
                    || (base.lastPathComponent == "Index-v3.sqlite" && stem == "Index-v2.scan") else { continue }
            targets.append(target)
        }
        guard !targets.isEmpty else { return }
        try root.validate()
        let plan = try ReviewedDirectoryRemoval.prepareAuthorized(targets, home: home, uid: getuid())
        for index in targets.indices { try root.validate(); try plan.remove(at: index) }
    }
    static func prune(base: URL, keeping: Set<URL>) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: base.deletingLastPathComponent().path) else { return }
        let root = try ReviewedDirectoryRemoval.CleanupRoot(base.deletingLastPathComponent().path)
        for target in try root.targets() {
            let file = URL(fileURLWithPath: target.path)
            let name = file.lastPathComponent
            let stem = name.hasSuffix("-wal") || name.hasSuffix("-shm") ? String(name.dropLast(4)) : name
            let suffix = stem.hasPrefix(base.lastPathComponent + ".") ? String(stem.dropFirst(base.lastPathComponent.count + 1)) : ""
            let legacy = base.lastPathComponent == "Index-v3.sqlite" && name == "Index-v2.scan"
            guard legacy || UUID(uuidString: suffix) != nil || stem == base.lastPathComponent else { continue }
            guard !keeping.contains(where: { $0.lastPathComponent == stem }), try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            try root.validate()
            let plan = try ReviewedDirectoryRemoval.prepareCleanup([target], within: [file.deletingLastPathComponent().path])
            try root.validate(); try plan.remove(at: 0)
        }
    }
}
