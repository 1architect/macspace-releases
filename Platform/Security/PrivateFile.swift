import Darwin
import Foundation

/// A pinned, no-follow local file boundary. Does not repair permissions on existing ancestors.
public final class PrivateFile {
    public struct Refusal: Error { public init() {} }
    private var descriptors: [Int32] = []
    private var identities: [stat] = []
    private var parts: [String]
    private let leaf: String
    public init(_ url: URL, createDirectories: Bool = false) throws {
        var path = url.path
        if path.hasPrefix("/var/") || path.hasPrefix("/tmp/") { path = "/private" + path }
        guard path.hasPrefix("/"), path.utf8.count < Int(PATH_MAX), !path.utf8.contains(0),
              !path.contains("//"), !path.hasSuffix("/"), geteuid() == getuid(), getuid() != 0 else { throw Refusal() }
        parts = path.split(separator: "/").map(String.init)
        guard parts.count > 1, !parts.contains("."), !parts.contains("..") else { throw Refusal() }
        leaf = parts.removeLast()
        do {
            try append(open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC))
            for part in parts {
                let parent = descriptors.last!
                var fd = openat(parent, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if fd < 0, errno == ENOENT, createDirectories {
                    guard mkdirat(parent, part, 0o700) == 0 || errno == EEXIST else { throw Refusal() }
                    fd = openat(parent, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                try append(fd)
            }
            guard identities.last?.st_uid == getuid() else { throw Refusal() }
            try validate()
        } catch { descriptors.forEach { close($0) }; descriptors = []; throw error }
    }
    deinit { descriptors.forEach { close($0) } }
    private func append(_ fd: Int32) throws {
        guard fd >= 0 else { throw Refusal() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid() || info.st_uid == 0,
              info.st_mode & 0o022 == 0 || (info.st_uid == 0 && info.st_mode & S_ISVTX != 0) else { close(fd); throw Refusal() }
        descriptors.append(fd); identities.append(info)
    }
    public func validate() throws {
        for i in parts.indices {
            var current = stat()
            guard fstatat(descriptors[i], parts[i], &current, AT_SYMLINK_NOFOLLOW) == 0,
                  current.st_mode & S_IFMT == S_IFDIR, Self.same(current, identities[i + 1]) else { throw Refusal() }
        }
    }
    private static func same(_ a: stat, _ b: stat) -> Bool { a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_uid == b.st_uid }
    private func safe(_ info: stat, privateMode: Bool = true) -> Bool {
        info.st_mode & S_IFMT == S_IFREG && info.st_uid == getuid() && info.st_nlink == 1 && info.st_mode & (privateMode ? 0o077 : 0o022) == 0
            && info.st_dev == identities.last!.st_dev
            && info.st_flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE | UF_APPEND | SF_APPEND | SF_DATALESS | SF_RESTRICTED) == 0
    }
    public func read(maximum: Int) throws -> Data? {
        try read(maximum: maximum, migrateLegacyPermissions: false)
    }
    /// Legacy state was owner-written with 0644 permissions. Tighten through the pinned
    /// descriptor; never accept another owner, links, or a group/world-writable file.
    public func readMigratingLegacyPermissions(maximum: Int) throws -> Data? {
        try read(maximum: maximum, migrateLegacyPermissions: true)
    }
    private func read(maximum: Int, migrateLegacyPermissions: Bool) throws -> Data? {
        try validate()
        let dir = descriptors.last!, fd = openat(dir, leaf, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw Refusal() }; defer { close(fd) }
        var info = stat(), named = stat()
        guard fstat(fd, &info) == 0, safe(info, privateMode: !migrateLegacyPermissions), info.st_size >= 0, info.st_size <= maximum,
              fstatat(dir, leaf, &named, AT_SYMLINK_NOFOLLOW) == 0, Self.same(info, named) else { throw Refusal() }
        if migrateLegacyPermissions, info.st_mode & 0o077 != 0 {
            guard fchmod(fd, 0o600) == 0, fstat(fd, &info) == 0, safe(info) else { throw Refusal() }
            try validate()
        }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n < 0, errno == EINTR { continue }
            guard n >= 0, result.count <= maximum - n else { throw Refusal() }
            if n == 0 { break }; result.append(contentsOf: buffer.prefix(n))
        }
        try validate()
        guard fstatat(dir, leaf, &named, AT_SYMLINK_NOFOLLOW) == 0, safe(named), Self.same(info, named),
              info.st_size == named.st_size, info.st_mtimespec.tv_sec == named.st_mtimespec.tv_sec,
              info.st_mtimespec.tv_nsec == named.st_mtimespec.tv_nsec else { throw Refusal() }
        return result
    }
    public final class ExclusiveLock {
        private let fd: Int32
        private let boundary: PrivateFile
        fileprivate init(_ fd: Int32, boundary: PrivateFile) { self.fd = fd; self.boundary = boundary }
        deinit { flock(fd, LOCK_UN); close(fd) }
    }
    public func exclusiveLock() throws -> ExclusiveLock {
        try validate()
        let dir = descriptors.last!
        var fd = openat(dir, leaf, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if fd < 0, errno == EEXIST { fd = openat(dir, leaf, O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK) }
        guard fd >= 0 else { throw Refusal() }
        var info = stat(), current = stat()
        guard fstat(fd, &info) == 0, safe(info), fstatat(dir, leaf, &current, AT_SYMLINK_NOFOLLOW) == 0,
              safe(current), Self.same(info, current), flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw Refusal() }
        do { try validate() } catch { close(fd); throw error }
        return ExclusiveLock(fd, boundary: self)
    }
    public func remove() throws {
        try validate()
        let dir = descriptors.last!, staging = ".preserved-" + UUID().uuidString
        var original = stat(), staged = stat()
        if fstatat(dir, leaf, &original, AT_SYMLINK_NOFOLLOW) != 0 { if errno == ENOENT { return }; throw Refusal() }
        guard safe(original), renameatx_np(dir, leaf, dir, staging, UInt32(RENAME_EXCL)) == 0 else { throw Refusal() }
        guard fstatat(dir, staging, &staged, AT_SYMLINK_NOFOLLOW) == 0, safe(staged), Self.same(original, staged) else { throw Refusal() }
        guard unlinkat(dir, staging, 0) == 0, fsync(dir) == 0 else { throw Refusal() }
    }
    public func write(_ data: Data) throws {
        try validate()
        let dir = descriptors.last!, temp = ".private-" + UUID().uuidString
        var original = stat()
        let exists = fstatat(dir, leaf, &original, AT_SYMLINK_NOFOLLOW) == 0
        guard exists ? safe(original) : errno == ENOENT else { throw Refusal() }
        let fd = openat(dir, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Refusal() }
        var retireTemp = true
        defer { close(fd); if retireTemp { _ = unlinkat(dir, temp, 0) } }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if n < 0, errno == EINTR { continue }; guard n > 0 else { throw Refusal() }; offset += n
            }
        }
        guard fsync(fd) == 0 else { throw Refusal() }
        try validate()
        if exists {
            // Exchange first, then verify the removed object before retiring it. Unexpected replacements are kept.
            guard renameatx_np(dir, temp, dir, leaf, UInt32(RENAME_SWAP)) == 0 else { throw Refusal() }
            var old = stat()
            guard fstatat(dir, temp, &old, AT_SYMLINK_NOFOLLOW) == 0, safe(old), Self.same(old, original) else {
                // Preserve the displaced entry under its private staging name; never delete a substituted object.
                retireTemp = false
                throw Refusal()
            }
        } else {
            guard renameatx_np(dir, temp, dir, leaf, UInt32(RENAME_EXCL)) == 0 else { throw Refusal() }
        }
        guard fsync(dir) == 0 else { throw Refusal() }
    }
}
