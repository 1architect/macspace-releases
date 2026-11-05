import Foundation
@preconcurrency import CoreServices
import MacSpaceDiskMapPrivileged

enum DiskLoginItems {
    static func belongs(_ path: String, to owner: AppOwner) -> Bool {
        path == owner.path || path.hasPrefix(owner.path + "/")
    }

    /// Legacy "Open at Login" bookmarks belong to the logged-in user. Run here,
    /// before the helper removes the bundle, while those bookmarks still resolve.
    @MainActor static func remove(for owner: AppOwner) throws {
        guard let list = LSSharedFileListCreate(nil, kLSSharedFileListSessionLoginItems.takeUnretainedValue(), nil)?.takeRetainedValue(),
              let items = LSSharedFileListCopySnapshot(list, nil)?.takeRetainedValue() as? [LSSharedFileListItem] else { return }
        let flags = UInt32(kLSSharedFileListNoUserInteraction | kLSSharedFileListDoNotMountVolumes)
        for item in items {
            guard let url = LSSharedFileListItemCopyResolvedURL(item, flags, nil)?.takeRetainedValue(),
                  belongs((url as URL).standardizedFileURL.path, to: owner) else { continue }
            let result = LSSharedFileListItemRemove(list, item)
            guard result == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(result)) }
        }
    }
}
