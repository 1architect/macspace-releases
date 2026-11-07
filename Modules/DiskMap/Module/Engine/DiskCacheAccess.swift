import Darwin
import Foundation
import MacSpacePlatform

/// Create and inspect cache artifacts through no-follow descriptors. Only the app-owned leaf
/// directory is made private; existing ancestor permissions are never changed.
final class DiskCacheAccess {
    private final class Descriptor {
        let fd: Int32
        let identity: stat
        init(_ fd: Int32) throws {
            guard fd >= 0 else { throw DiskCacheAccess.failure() }
            var value = stat()
            guard fstat(fd, &value) == 0 else { close(fd); throw DiskCacheAccess.failure() }
            self.fd = fd; identity = value
        }
        deinit { close(fd) }
    }
    let path: String
    private let parts: [String]
    private var directories: [Descriptor] = []
    private var file: Descriptor?
    private static func failure() -> DiskDatabase.Failure { .init(message: "Cannot open disk index") }

    init(_ url: URL) throws {
        var path = url.path
        // These root-owned macOS aliases are outside the user-controlled cache boundary.
        if path.hasPrefix("/var/") || path.hasPrefix("/tmp/") { path = "/private" + path }
        guard FileReviewPolicy.isNormalizedAbsolutePath(path, allowTrailingSlash: false),
              path.utf8.count < Int(PATH_MAX), geteuid() == getuid(), getuid() != 0 else { throw Self.failure() }
        self.path = path; parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { throw Self.failure() }
        directories.append(try Descriptor(open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)))
        var createdLeafDirectory = false
        for (index, part) in parts.dropLast().enumerated() {
            let parent = directories.last!.fd
            var fd = openat(parent, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if fd < 0, errno == ENOENT {
                let made = mkdirat(parent, part, 0o700)
                guard made == 0 || errno == EEXIST else { throw Self.failure() }
                if index == parts.count - 2, made == 0 { createdLeafDirectory = true }
                fd = openat(parent, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            let directory = try Descriptor(fd)
            let value = directory.identity
            guard value.st_uid == 0 || value.st_uid == getuid(),
                  value.st_mode & 0o022 == 0 || (value.st_uid == 0 && value.st_mode & S_ISVTX != 0) else { throw Self.failure() }
            directories.append(directory)
        }
        let parent = directories.last!
        guard parent.identity.st_uid == getuid() else { throw Self.failure() }
        if createdLeafDirectory || parts.dropLast().last == "com.macspace.disk-map" {
            guard fchmod(parent.fd, 0o700) == 0 else { throw Self.failure() }
        }
        file = try Descriptor(openat(parent.fd, parts.last!, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600))
        guard let file, Self.safeFile(file.identity), fchmod(file.fd, 0o600) == 0 else { throw Self.failure() }
        for suffix in ["-wal", "-shm", "-journal"] {
            var value = stat()
            if fstatat(parent.fd, parts.last! + suffix, &value, AT_SYMLINK_NOFOLLOW) == 0 {
                guard Self.safeFile(value) else { throw Self.failure() }
            } else if errno != ENOENT { throw Self.failure() }
        }
        try validate()
    }

    private static func safeFile(_ value: stat) -> Bool {
        value.st_mode & S_IFMT == S_IFREG && value.st_uid == getuid() && value.st_nlink == 1
            && value.st_flags & UInt32(SF_DATALESS | SF_RESTRICTED | SF_IMMUTABLE | UF_IMMUTABLE | UF_APPEND | SF_APPEND) == 0
    }

    func validate() throws {
        for index in 1..<directories.count {
            var current = stat()
            let expected = directories[index].identity
            guard fstatat(directories[index - 1].fd, parts[index - 1], &current, AT_SYMLINK_NOFOLLOW) == 0,
                  current.st_mode & S_IFMT == S_IFDIR,
                  current.st_dev == expected.st_dev, current.st_ino == expected.st_ino, current.st_uid == expected.st_uid else { throw Self.failure() }
        }
        var current = stat()
        guard let file, fstatat(directories.last!.fd, parts.last!, &current, AT_SYMLINK_NOFOLLOW) == 0,
              Self.safeFile(current), current.st_dev == file.identity.st_dev, current.st_ino == file.identity.st_ino else { throw Self.failure() }
    }
}
