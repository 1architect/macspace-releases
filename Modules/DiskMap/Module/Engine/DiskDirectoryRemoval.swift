import Foundation
import MacSpaceSdk
import MacSpacePlatform

/// An explicitly confirmed whole folder, bounded to personal locations and preflighted before any mutation.
enum DiskDirectoryRemoval {
    static let defaultHome = FileManager.default.homeDirectoryForCurrentUser.path
    static func action(_ path: String, node: DiskDirectory?, home: String = defaultHome) -> Action? {
        let live = FileReviewPolicy.livePath(path)
        guard let node, node.readable, node.ownershipID == nil,
              ReviewedDirectoryRemoval.includesPersonal(live, home: home),
              let identity = ReviewedDirectoryRemoval.Identity(live) else { return nil }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let evidence = try? encoder.encode(identity) else { return nil }
        let trash = FileRemovalSettings.movesToTrash()
        return Action(id: "deleteFolder", title: loc("Delete"), symbol: "trash", role: .destructive,
            parameters: ["path": path, "reviewed": String(decoding: evidence, as: UTF8.self), "trash": trash ? "1" : "0"],
            confirmation: Confirmation(title: trash ? loc("Move folder to Trash?") : loc("Delete this folder?"),
                message: trash ? loc("Includes everything inside.") : loc("Permanently deletes everything inside."),
                confirmTitle: trash ? loc("Move to Trash") : loc("Delete")), requires: [.fullDiskAccess], workingTitle: loc("Freeing space"))
    }

    static func remove(_ path: String, expected: ReviewedDirectoryRemoval.Identity, moveToTrash: Bool,
                       home: String = defaultHome) throws -> UInt64 {
        let plan = try ReviewedDirectoryRemoval.preparePersonal([.init(path: FileReviewPolicy.livePath(path), expected: expected)], home: home)
        let bytes = plan.bytes
        if moveToTrash { try plan.trash(at: 0) } else { try plan.remove(at: 0) }
        return bytes
    }
}
