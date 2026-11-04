import Darwin
import Foundation

/// Ordinary removal is unprivileged and rooted in no-follow directory descriptors.
public enum ReviewedFileRemoval {
    public static func remove(_ path: String, expected: FileReviewIdentity, moveToTrash: Bool, home: String = FileManager.default.homeDirectoryForCurrentUser.path) throws {
        try remove(path, expected: expected, moveToTrash: moveToTrash, permitted: FileReviewPolicy.includes(path, home: home))
    }
    public static func removeAppData(_ path: String, expected: FileReviewIdentity, moveToTrash: Bool, home: String = FileManager.default.homeDirectoryForCurrentUser.path) throws {
        try remove(path, expected: expected, moveToTrash: moveToTrash, permitted: AppDataReviewPolicy.includesFile(path, home: home))
    }
    private static func remove(_ path: String, expected: FileReviewIdentity, moveToTrash: Bool, permitted: Bool) throws {
        guard getuid() != 0, geteuid() == getuid(), permitted, expected.uid == getuid() else { throw CocoaError(.fileWriteNoPermission) }
        let canonical = FileReviewPolicy.livePath(path)
        let components = canonical.split(separator: "/").map(String.init)
        guard let leaf = components.last else { throw CocoaError(.fileWriteInvalidFileName) }
        var parent = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else { throw POSIXError(.EACCES) }
        defer { close(parent) }
        for part in components.dropLast() {
            let next = openat(parent, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw POSIXError(.EACCES) }
            close(parent); parent = next
        }
        let file = openat(parent, leaf, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw POSIXError(.EACCES) }
        defer { close(file) }
        var value = stat(), parentInfo = stat()
        guard fstat(file, &value) == 0, fstat(parent, &parentInfo) == 0,
              value.st_mode & S_IFMT == S_IFREG,
              value.st_flags & UInt32(SF_DATALESS | SF_RESTRICTED | SF_IMMUTABLE | UF_IMMUTABLE) == 0,
              FileReviewIdentity(value) == expected else { throw CocoaError(.fileReadUnknown) }
        let directory = (canonical as NSString).deletingLastPathComponent
        if moveToTrash {
            var coordinationError: NSError?, removalError: Error?
            NSFileCoordinator().coordinate(writingItemAt: URL(fileURLWithPath: canonical), options: .forMoving, error: &coordinationError) { url in
                do {
                    var current = stat(), currentParent = stat()
                    guard url.path == canonical, lstat(directory, &currentParent) == 0,
                          currentParent.st_dev == parentInfo.st_dev, currentParent.st_ino == parentInfo.st_ino,
                          URL(fileURLWithPath: canonical).resolvingSymlinksInPath().path == canonical,
                          fstatat(parent, leaf, &current, AT_SYMLINK_NOFOLLOW) == 0,
                          current.st_mode & S_IFMT == S_IFREG, FileReviewIdentity(current) == expected else { throw CocoaError(.fileWriteNoPermission) }
                    // Use the original URL so Finder retains its filename and Put Back location.
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                } catch { removalError = error }
            }
            if let coordinationError { throw coordinationError }
            if let removalError { throw removalError }
            return
        }
        let staged = ".macspace-review-" + UUID().uuidString
        guard renameatx_np(parent, leaf, parent, staged, UInt32(RENAME_EXCL)) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let stagedPath = directory + "/" + staged
        do {
            var moved = stat()
            guard fstatat(parent, staged, &moved, AT_SYMLINK_NOFOLLOW) == 0,
                  moved.st_dev == value.st_dev, moved.st_ino == value.st_ino,
                  moved.st_uid == value.st_uid, moved.st_size == value.st_size,
                  moved.st_mtimespec.tv_sec == value.st_mtimespec.tv_sec,
                  moved.st_mtimespec.tv_nsec == value.st_mtimespec.tv_nsec else { throw CocoaError(.fileReadUnknown) }
                guard unlinkat(parent, staged, 0) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            // Never overwrite a new file that appeared at the original path during removal.
            if renameatx_np(parent, staged, parent, leaf, UInt32(RENAME_EXCL)) != 0 {
                throw NSError(domain: "MacSpace.FileRemoval", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Removal failed. The preserved file is at " + stagedPath])
            }
            throw error
        }
    }
}
