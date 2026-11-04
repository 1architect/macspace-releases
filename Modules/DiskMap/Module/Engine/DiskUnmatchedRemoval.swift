import Foundation
import Darwin
import MacSpaceDiskMapPrivileged
import MacSpaceSdk
import MacSpacePlatform

/// Manual review is distinct from uninstall ownership. Never infer an automatic cleanup target from a missing app.
enum DiskUnmatchedRemoval {
    static func eligible(_ path: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> Bool {
        let parent = (path as NSString).deletingLastPathComponent
        guard (DiskApplications.reviewBases + AppDataReviewPolicy.fileBases).contains(where: { parent == home + "/Library/" + $0 }) else { return false }
        return DiskAppDataRemoval.target(path, home: home) != nil
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
        let snapshots = targets.compactMap { DiskAppDataRemoval.target($0.path, home: home) }
        guard snapshots.count == targets.count, zip(targets, snapshots).allSatisfy({ $0.identity == $1.identity && $0.fileIdentity == $1.fileIdentity }) else { return nil }
        let originalIDs = Dictionary(uniqueKeysWithValues: zip(snapshots, targets).map { ($0.id, $1.choiceID) })
        do {
            let result = try DiskAppDataRemoval.remove(ids: Set(snapshots.map(\.id)), candidates: snapshots, moveToTrash: false,
                home: home, removeForTesting: remove, progress: { update in
                    progress(.init(fraction: update.fraction, message: loc("Freeing space"), finished: update.finished.compactMap { originalIDs[$0] }))
                })
            return DiskFileRemoval.Result(targets: targets.map(\.path), failures: result.failures)
        } catch {
            return DiskFileRemoval.Result(targets: targets.map(\.path), failures: [error.localizedDescription])
        }
    }
}
