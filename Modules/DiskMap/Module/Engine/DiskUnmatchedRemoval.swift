import Foundation
import Darwin
import MacSpaceDiskMapPrivileged
import MacSpaceSdk
import MacSpacePlatform

/// Manual review is distinct from uninstall ownership. Never infer an automatic cleanup target from a missing app.
enum DiskUnmatchedRemoval {
    static func eligible(_ path: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> Bool {
        let parent = (path as NSString).deletingLastPathComponent
        guard ReviewedDirectoryRemoval.includes(path, home: home),
              DiskApplications.reviewBases.contains(where: { parent == home + "/Library/" + $0 }),
              AppOwnership.safeExisting(path) else { return false }
        var info = stat()
        return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR && info.st_uid == getuid()
            && info.st_flags & UInt32(SF_DATALESS | SF_RESTRICTED | SF_IMMUTABLE | UF_IMMUTABLE) == 0
    }
    static func execute(ids: Set<String>, candidates: [AppLeftover],
                        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                        remove: ((String) throws -> Void)? = nil,
                        progress: ProgressSink = { _ in }) -> DiskFileRemoval.Result? {
        let targets = candidates.filter { ids.contains($0.choiceID) }
        // Resolve every ID and compare the exact identities reviewed by the user before any mutation.
        guard !ids.isEmpty, Set(targets.map(\.choiceID)) == ids,
              Set(targets.map(\.path)).count == targets.count,
              targets.allSatisfy({ $0.identity != nil && eligible($0.path, home: home) && AppFileIdentity(path: $0.path) == $0.identity }) else { return nil }
        let plan: ReviewedDirectoryRemoval.Plan
        do {
            plan = try ReviewedDirectoryRemoval.prepare(targets.map { target in
                let identity = target.identity!
                return .init(path: target.path, expected: .init(device: identity.device, inode: identity.inode, uid: identity.uid,
                    modifiedSeconds: identity.modifiedSeconds, modifiedNanos: identity.modifiedNanos))
            }, home: home)
        } catch {
            return DiskFileRemoval.Result(targets: targets.map(\.path), failures: [error.localizedDescription])
        }
        var failures: [String] = [], finished: [String] = []
        for (n, target) in targets.enumerated() {
            do {
                guard eligible(target.path, home: home), AppFileIdentity(path: target.path) == target.identity else {
                    throw CocoaError(.fileWriteNoPermission)
                }
                if let remove {
                    // Test injection still requires the complete batch preflight.
                    try plan.validate(at: n)
                    try remove(target.path)
                } else { try plan.remove(at: n) }
                finished.append(target.choiceID)
            } catch { failures.append(target.path + ": " + error.localizedDescription) }
            progress(ActionProgress(fraction: Double(n + 1) / Double(targets.count), message: loc("Freeing space"), finished: finished))
        }
        return DiskFileRemoval.Result(targets: targets.map(\.path), failures: failures)
    }
}
