import Foundation
import Darwin
import MacSpacePlatform
import MacSpaceDiskMapPrivileged
import MacSpaceSdk

/// Optional data is explicitly reviewed; inferred associations never enter the privileged uninstall plan.
enum DiskAppDataRemoval {
    enum Failure: LocalizedError {
        case tooMany, openFiles
        var errorDescription: String? {
            switch self {
            case .tooMany: loc("Select at most 32 app-data locations at a time.")
            case .openFiles: loc("Selected app data is in use. Quit the app and try again.")
            }
        }
    }
    struct Target: Codable, Equatable, Sendable {
        var path: String
        var identity: AppFileIdentity
        var fileIdentity: FileReviewIdentity?
        var id: String {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return "reviewed-app-data:" + ((try? encoder.encode(self)) ?? Data()).base64EncodedString()
        }
    }
    struct Result { var removed: [String] = []; var failures: [String] = [] }
    static func target(_ path: String, home: String) -> Target? {
        var info = stat()
        guard AppOwnership.safeExisting(path), lstat(path, &info) == 0, info.st_uid == getuid(),
              info.st_flags & UInt32(SF_DATALESS | SF_RESTRICTED | SF_IMMUTABLE | UF_IMMUTABLE | SF_APPEND | UF_APPEND | SF_NOUNLINK | UF_DATAVAULT) == 0,
              let identity = AppFileIdentity(path: path) else { return nil }
        if info.st_mode & S_IFMT == S_IFDIR, AppDataReviewPolicy.includesDirectory(path, home: home) {
            return Target(path: path, identity: identity)
        }
        if info.st_mode & S_IFMT == S_IFREG, AppDataReviewPolicy.includesFile(path, home: home), let file = FileReviewIdentity(path) {
            return Target(path: path, identity: identity, fileIdentity: file)
        }
        return nil
    }
    static func candidates(_ app: DiskApplication, apps: [DiskApplication], home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> [Target] {
        let foreign = Set(apps.filter { $0.owner.path != app.owner.path }.flatMap(\.ownership).flatMap(\.paths))
        let orderedForeign = foreign.sorted()
        func overlapsForeign(_ path: String) -> Bool {
            if foreign.contains("/") { return true }
            var ancestor = path
            while !ancestor.isEmpty {
                if foreign.contains(ancestor) { return true }
                guard let slash = ancestor.lastIndex(of: "/"), slash != ancestor.startIndex else { break }
                ancestor = String(ancestor[..<slash])
            }
            let prefix = path + "/"
            var lower = 0, upper = orderedForeign.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if orderedForeign[middle] < prefix { lower = middle + 1 } else { upper = middle }
            }
            return lower < orderedForeign.count && orderedForeign[lower].hasPrefix(prefix)
        }
        let paths = app.ownership.filter {
            $0.source != "bundle" && !$0.source.hasPrefix("receiptManifest") && $0.confidence != .shared && $0.ownerPaths == [app.owner.path]
        }.flatMap(\.paths).filter { path in
            path != app.owner.path && !path.hasPrefix(app.owner.path + "/") && !overlapsForeign(path)
        }
        return AppOwnership.normalizedPaths(paths).compactMap { target($0, home: home) }
    }
    /// Re-resolve every frozen choice and preflight the whole batch before touching user data.
    static func remove(ids: Set<String>, candidates: [Target], moveToTrash: Bool,
                       home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                       removeForTesting: ((String) throws -> Void)? = nil,
                       progress: ProgressSink = { _ in }) throws -> Result {
        guard ids.count <= 32 else { throw Failure.tooMany }
        let selected = candidates.filter { ids.contains($0.id) }
        guard Set(selected.map(\.id)) == ids, AppOwnership.normalizedPaths(selected.map(\.path)).count == selected.count,
              selected.allSatisfy({ target($0.path, home: home) == $0 }) else { throw CocoaError(.fileReadUnknown) }
        let open = OpenFileUse.inspect(Set(selected.map(\.path)), includesDescendants: true)
        guard selected.allSatisfy({ open[$0.path]?.isEmpty != false }) else { throw Failure.openFiles }
        let folders = selected.filter { $0.fileIdentity == nil }
        let plan = try folders.isEmpty ? nil : ReviewedDirectoryRemoval.prepare(folders.map {
            .init(path: $0.path, expected: .init(device: $0.identity.device, inode: $0.identity.inode, uid: $0.identity.uid,
                modifiedSeconds: $0.identity.modifiedSeconds, modifiedNanos: $0.identity.modifiedNanos))
        }, home: home)
        var result = Result(), finished: [String] = []
        for item in selected {
            do {
                guard target(item.path, home: home) == item else { throw CocoaError(.fileReadUnknown) }
                if let removeForTesting {
                    if let n = folders.firstIndex(of: item) { try plan?.validate(at: n) }
                    try removeForTesting(item.path)
                } else if let file = item.fileIdentity {
                    try ReviewedFileRemoval.removeAppData(item.path, expected: file, moveToTrash: moveToTrash, home: home)
                } else if let n = folders.firstIndex(of: item) {
                    if moveToTrash { try plan?.trash(at: n) } else { try plan?.remove(at: n) }
                }
                result.removed.append(item.path); finished.append(item.id)
                progress(.init(fraction: Double(finished.count) / Double(max(selected.count, 1)), message: loc("Uninstalling"), finished: finished))
            } catch {
                result.failures.append(item.path + ": " + error.localizedDescription)
                break // Preserve the app when optional data cannot be removed completely.
            }
        }
        return result
    }
}
