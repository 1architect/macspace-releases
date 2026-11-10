import Foundation
import MacSpaceSdk
import MacSpacePlatform

/// Manual review is distinct from uninstall ownership. Never infer an automatic cleanup target from a missing app.
enum DiskUnmatchedRemoval {
    static func eligible(_ path: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> Bool {
        target(path, home: home) != nil
    }

    private static func target(_ path: String, home: String) -> DiskAppDataRemoval.Target? {
        let parent = (path as NSString).deletingLastPathComponent
        guard (DiskApplications.reviewBases + AppDataReviewPolicy.fileBases).contains(where: { parent == home + "/Library/" + $0 }) else { return nil }
        return DiskAppDataRemoval.target(path, home: home)
    }

    static func execute(ids: Set<String>, candidates: [AppLeftover],
                        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                        remove: ((String) throws -> Void)? = nil,
                        progress: ProgressSink = { _ in }) -> DiskFileRemoval.Result? {
        let targets = candidates.filter { ids.contains($0.choiceID) }
        // Resolve every ID and compare the exact identities reviewed by the user before any mutation.
        guard !ids.isEmpty, Set(targets.map(\.choiceID)) == ids,
              Set(targets.map(\.path)).count == targets.count else { return nil }
        let snapshots = targets.compactMap { target($0.path, home: home) }
        guard snapshots.count == targets.count, zip(targets, snapshots).allSatisfy({ $0.identity == $1.identity && $0.fileIdentity == $1.fileIdentity }) else { return nil }

        // These locations are independent. Keep just one directory plan open and report
        // failures per location while continuing with the rest of the reviewed selection.
        var result = DiskFileRemoval.Result(targets: [], failures: [])
        var finished: [String] = []
        for (index, pair) in zip(targets, snapshots).enumerated() {
            let (reviewed, target) = pair
            if Task.isCancelled {
                result.failures.append(loc("Removal was canceled."))
                break
            }
            do {
                guard DiskAppDataRemoval.target(target.path, home: home) == target else { throw CocoaError(.fileReadUnknown) }
                if let identity = target.fileIdentity {
                    guard OpenFileUse.inspect([target.path])[target.path]?.isEmpty != false else { throw DiskAppDataRemoval.Failure.openFiles }
                    result.targets.append(target.path)
                    if let remove { try remove(target.path) }
                    else { try ReviewedFileRemoval.removeAppData(target.path, expected: identity, moveToTrash: false, home: home) }
                } else {
                    let identity = target.identity
                    let plan = try ReviewedDirectoryRemoval.prepare([.init(path: target.path, expected: .init(device: identity.device,
                        inode: identity.inode, uid: identity.uid, modifiedSeconds: identity.modifiedSeconds, modifiedNanos: identity.modifiedNanos))], home: home)
                    result.targets.append(target.path)
                    if let remove {
                        try plan.validate(at: 0)
                        try remove(target.path)
                    } else {
                        try plan.remove(at: 0)
                    }
                }
                result.removedBytes += reviewed.bytes
                finished.append(reviewed.choiceID)
            } catch let failure as ReviewedDirectoryRemoval.Failure {
                result.failures.append(failure.localizedDescription)
            } catch {
                result.failures.append(target.path + ": " + error.localizedDescription)
            }
            progress(.init(fraction: Double(index + 1) / Double(targets.count), message: loc("Freeing space"), finished: finished))
        }
        return result
    }
}
