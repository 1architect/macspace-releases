import Darwin
import Foundation
import CryptoKit

/// Unprivileged directory removal with separate app-data and explicit personal-folder boundaries.
/// A private on-disk manifest bounds memory while retaining every preflight identity.
public enum ReviewedDirectoryRemoval {
    public struct Identity: Codable, Equatable, Sendable {
        public let device: Int32
        public let inode: UInt64
        public let uid: UInt32
        public let modifiedSeconds: Int64
        public let modifiedNanos: Int64
        public init(device: Int32, inode: UInt64, uid: UInt32, modifiedSeconds: Int64, modifiedNanos: Int64) {
            self.device = device; self.inode = inode; self.uid = uid
            self.modifiedSeconds = modifiedSeconds; self.modifiedNanos = modifiedNanos
        }
        public init?(_ path: String) {
            var value = stat()
            guard lstat(path, &value) == 0, value.st_mode & S_IFMT == S_IFDIR,
                  value.st_uid == getuid(), value.st_flags & ReviewedDirectoryRemoval.protectedFlags == 0 else { return nil }
            self.init(value)
        }
        fileprivate init(_ value: stat) {
            self.init(device: value.st_dev, inode: value.st_ino, uid: value.st_uid,
                      modifiedSeconds: Int64(value.st_mtimespec.tv_sec), modifiedNanos: Int64(value.st_mtimespec.tv_nsec))
        }
        fileprivate func matches(_ value: stat) -> Bool { self == Identity(value) }
    }
    public struct Target: Sendable {
        public let path: String
        public let expected: Identity
        public init(path: String, expected: Identity) { self.path = path; self.expected = expected }
    }
    public struct Failure: Error, LocalizedError, Sendable {
        public let path: String
        public let preservedPath: String?
        public let reason: String
        public var errorDescription: String? {
            path + ": " + reason + (preservedPath.map { ". Preserved data: " + $0 } ?? "")
        }
        fileprivate init(_ path: String, _ reason: String, preservedPath: String? = nil) {
            self.path = path; self.reason = reason; self.preservedPath = preservedPath
        }
    }

    private static let protectedFlags = UInt32(SF_DATALESS | SF_RESTRICTED | SF_IMMUTABLE | UF_IMMUTABLE | SF_APPEND | UF_APPEND | SF_NOUNLINK | UF_DATAVAULT | SF_FIRMLINK)
    private static let maxDepth = 48, maxEntries = 100_000, maxTargets = 32
    private static let maxManifestBytes = 64 * 1024 * 1024

    public static func includes(_ path: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> Bool {
        func valid(_ value: String) -> Bool {
            value.hasPrefix("/") && value.utf8.count < Int(PATH_MAX) && !value.utf8.contains(0)
                && !value.contains("//") && !value.hasSuffix("/")
                && !value.split(separator: "/").contains { $0 == "." || $0 == ".." }
        }
        guard getuid() != 0, geteuid() == getuid(), valid(home), valid(path) else { return false }
        return AppDataReviewPolicy.includesDirectory(path, home: home)
    }

    /// All targets must finish preflight before a Plan can mutate any of them.
    public static func prepare(_ targets: [Target], home: String = FileManager.default.homeDirectoryForCurrentUser.path) throws -> Plan {
        try prepare(targets, home: home, personal: false)
    }

    /// Whole personal folders use the same descriptor-based preflight and guarded removal as app-data directories.
    /// The home itself, app packages, hidden and managed roots remain outside this boundary.
    public static func includesPersonal(_ path: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> Bool {
        guard getuid() != 0, geteuid() == getuid(), path.hasPrefix(home + "/") else { return false }
        switch FileReviewPolicy.exclusion(path, home: home) {
        case nil, .outsidePersonalLocation: return true
        default: return false
        }
    }

    public static func preparePersonal(_ targets: [Target], home: String = FileManager.default.homeDirectoryForCurrentUser.path) throws -> Plan {
        try prepare(targets, home: home, personal: true)
    }

    public final class CleanupRoot {
        public let path: String
        private var chain: [Descriptor] = []
        private let parts: [String]
        public init(_ path: String) throws {
            let path = ReviewedDirectoryRemoval.canonicalCleanupPath(path)
            guard FileReviewPolicy.isNormalizedAbsolutePath(path, allowTrailingSlash: false), path != "/" else { throw Failure(path, "Invalid cleanup root") }
            self.path = path; parts = path.split(separator: "/").map(String.init)
            chain.append(try Descriptor(open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC), path: path))
            for part in parts { chain.append(try Descriptor(openat(chain.last!.fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC), path: path)) }
            try validate()
        }
        public func validate() throws {
            for i in parts.indices {
                var current = stat()
                guard fstatat(chain[i].fd, parts[i], &current, AT_SYMLINK_NOFOLLOW) == 0,
                      current.st_mode & S_IFMT == S_IFDIR, current.st_dev == chain[i+1].initial.st_dev,
                      current.st_ino == chain[i+1].initial.st_ino, current.st_uid == chain[i+1].initial.st_uid else { throw Failure(path, "Cleanup root changed") }
            }
        }
        public func targets() throws -> [Target] {
            try validate()
            let copy = fcntl(chain.last!.fd, F_DUPFD_CLOEXEC, 0)
            guard copy >= 0, let stream = fdopendir(copy) else { if copy >= 0 { close(copy) }; throw Failure(path, "Cannot enumerate cleanup root") }
            defer { closedir(stream) }
            var result: [Target] = []
            while true {
                errno = 0
                guard let entry = readdir(stream) else { guard errno == 0 else { throw Failure(path, "Incomplete cleanup listing") }; break }
                let name = withUnsafePointer(to: entry.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX)+1) { String(validatingCString: $0) } }
                guard let name else { throw Failure(path, "Invalid cleanup name") }
                if name == "." || name == ".." { continue }
                var info = stat()
                guard fstatat(chain.last!.fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw Failure(path, "Cleanup entry changed") }
                result.append(Target(path: path + "/" + name, expected: Identity(info)))
                guard result.count <= 100_000 else { throw Failure(path, "Cleanup listing limit") }
            }
            try validate(); return result
        }
    }

    /// Narrow cleanup adapters authorize roots independently before calling the descriptor primitive.
    public static func cleanupIdentity(_ path: String) -> Identity? {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_uid == getuid(),
              [S_IFREG, S_IFDIR].contains(info.st_mode & S_IFMT), info.st_flags & protectedFlags == 0 else { return nil }
        return Identity(info)
    }
    private static func canonicalCleanupPath(_ path: String) -> String {
        path.hasPrefix("/var/") || path.hasPrefix("/tmp/") ? "/private" + path : path
    }
    public static func prepareCleanup(_ targets: [Target], within roots: [String]) throws -> Plan {
        let roots = roots.map(canonicalCleanupPath)
        let targets = targets.map { Target(path: canonicalCleanupPath($0.path), expected: $0.expected) }
        guard !roots.isEmpty, targets.allSatisfy({ target in
            roots.contains { root in FileReviewPolicy.isNormalizedAbsolutePath(root, allowTrailingSlash: false) && root != "/" && target.path.hasPrefix(root + "/") }
        }) else { throw Failure("", "Cleanup target is outside its allowed root") }
        let pinned = try roots.filter { root in targets.contains { $0.path.hasPrefix(root + "/") } }.map(CleanupRoot.init)
        let plan = try prepareAuthorized(targets, home: FileManager.default.homeDirectoryForCurrentUser.path, uid: getuid())
        for root in pinned { try root.validate() }
        plan.cleanupRoots = pinned
        return plan
    }

    /// The helper must first authorize an exact ownership plan. This routine adds no path authorization;
    /// it pins that plan's files/directories and uses the same guarded, manifest-based deletion primitive.
    public static func prepareAuthorized(_ targets: [Target], home: String, uid: uid_t) throws -> Plan {
        guard geteuid() == getuid(), getuid() == 0 || getuid() == uid,
              !targets.isEmpty, targets.count <= 4096,
              Set(targets.map(\.path)).count == targets.count else { throw Failure(home, "Invalid authorized removal plan") }
        var items: [Prepared] = [], entries = 0
        for target in targets {
            guard FileReviewPolicy.isNormalizedAbsolutePath(target.path, allowTrailingSlash: false),
                  target.path.utf8.count < Int(PATH_MAX) else {
                throw Failure(target.path, "Invalid authorized path")
            }
            guard target.expected.uid == uid || (getuid() == 0 && target.expected.uid == 0) else {
                throw Failure(target.path, "Authorized target has a different owner")
            }
            let item = try Prepared(target, home: home, permitsSymbolicLinks: true, authorizedUID: uid)
            try item.preflight(entries: &entries)
            items.append(item)
        }
        for item in items { try item.validate() }
        return Plan(items)
    }

    private static func prepare(_ targets: [Target], home: String, personal: Bool) throws -> Plan {
        guard !targets.isEmpty, targets.count <= maxTargets, Set(targets.map(\.path)).count == targets.count else {
            throw Failure(home, "Invalid or excessive directory selection")
        }
        for target in targets {
            guard (personal ? includesPersonal(target.path, home: home) : includes(target.path, home: home)), target.expected.uid == getuid() else {
                throw Failure(target.path, "Directory is outside the permitted ownership boundary")
            }
        }
        // Inspect before opening our own directory descriptors: they otherwise look like users of the tree.
        let inUse = OpenFileUse.inspect(Set(targets.map(\.path)), includesDescendants: true)
        for target in targets where inUse[target.path]?.isEmpty == false {
            throw Failure(target.path, "Directory has observable open file descriptors")
        }
        var prepared: [Prepared] = [], entries = 0
        for target in targets {
            let item = try Prepared(target, home: home, permitsSymbolicLinks: personal)
            try item.preflight(entries: &entries)
            prepared.append(item)
        }
        for item in prepared { try item.validate() }
        return Plan(prepared)
    }

    /// Single-use entries. Keep this plan on the calling executor; it is deliberately not Sendable.
    public final class Plan {
        private let items: [Prepared]
        fileprivate var cleanupRoots: [CleanupRoot] = []
        private var attempted: Set<Int> = []
        fileprivate init(_ items: [Prepared]) { self.items = items }
        public var bytes: UInt64 { items.reduce(0) { $0 + $1.bytes } }
        public func trash(at index: Int) throws {
            try validate(at: index)
            attempted.insert(index)
            try items[index].trash()
        }
        public func validate(at index: Int) throws {
            for root in cleanupRoots { try root.validate() }
            guard items.indices.contains(index), !attempted.contains(index) else { throw Failure("", "Invalid or already attempted target") }
            try items[index].validate()
        }
        public func remove(at index: Int) throws {
            try validate(at: index)
            attempted.insert(index)
            try items[index].remove()
        }
    }

    fileprivate final class Descriptor {
        let fd: Int32
        let initial: stat
        init(_ fd: Int32, path: String) throws {
            guard fd >= 0 else { throw failure(path, "Cannot open directory") }
            self.fd = fd
            var value = stat()
            guard fstat(fd, &value) == 0 else { close(fd); throw failure(path, "Cannot inspect directory") }
            initial = value
        }
        deinit { close(fd) }
    }
    private static func failure(_ path: String, _ reason: String) -> Failure {
        let code = errno
        return Failure(path, reason + " (errno " + String(code) + ")")
    }
    private static func sameObject(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_uid == b.st_uid && a.st_mode == b.st_mode
    }
    private static func unchanged(_ a: stat, _ b: stat, afterRename: Bool = false) -> Bool {
        guard sameObject(a, b), a.st_flags == b.st_flags, a.st_size == b.st_size, a.st_nlink == b.st_nlink,
              a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec, a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec else { return false }
        return afterRename || (a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec)
    }
    private static func safe(_ value: stat, device: Int32, path: String, permitsSymbolicLinks: Bool = false, authorizedUID: uid_t? = nil) throws {
        let kind = value.st_mode & S_IFMT
        guard value.st_uid == getuid() || authorizedUID == value.st_uid,
              value.st_dev == device, value.st_flags & protectedFlags == 0,
              kind == S_IFDIR || (kind == S_IFREG && value.st_nlink == 1) || (permitsSymbolicLinks && kind == S_IFLNK) else {
            throw Failure(path, "Unsafe owner, mount, flags, link, or file type")
        }
    }
    private static func named(_ parent: Int32, _ name: String, path: String) throws -> stat {
        var value = stat()
        guard fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else { throw failure(path, "Cannot inspect directory entry") }
        return value
    }
    private static func local(_ fd: Int32, path: String) throws -> String {
        var fs = statfs()
        guard fstatfs(fd, &fs) == 0, fs.f_flags & UInt32(MNT_LOCAL) != 0,
              fs.f_flags & UInt32(MNT_RDONLY) == 0 else { throw Failure(path, "Cannot establish a writable local filesystem") }
        return withUnsafePointer(to: fs.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }

    /// Anonymous spool: one length-prefixed name and native stat per entry, plus directory end markers.
    /// It is never deserialized across processes or persisted between runs.
    fileprivate final class Manifest {
        let stream: UnsafeMutablePointer<FILE>
        private let key = SymmetricKey(size: .bits256)
        private var written: UInt64 = 0, reading: UInt64 = 0
        private func ordinal(_ value: UInt64) -> Data { var value = value.bigEndian; return withUnsafeBytes(of: &value) { Data($0) } }
        init(path: String) throws {
            guard let stream = tmpfile() else { throw failure(path, "Cannot allocate preflight manifest") }
            guard fchmod(fileno(stream), 0o600) == 0, fcntl(fileno(stream), F_SETFD, FD_CLOEXEC) == 0 else {
                fclose(stream); throw failure(path, "Cannot protect preflight manifest")
            }
            self.stream = stream
        }
        deinit { fclose(stream) }
        func write(_ name: String, _ info: stat = stat(), path: String) throws {
            let bytes = Data(name.utf8)
            guard bytes.count <= Int(NAME_MAX), ftell(stream) >= 0, ftell(stream) < maxManifestBytes - 1024 else { throw Failure(path, "Preflight manifest limit exceeded") }
            var info = info
            var payload = withUnsafeBytes(of: &info) { Data($0) }; payload.append(bytes)
            guard let encrypted = try AES.GCM.seal(payload, using: key, authenticating: ordinal(written)).combined else { throw Failure(path, "Cannot seal preflight record") }
            var length = UInt16(encrypted.count)
            guard fwrite(&length, MemoryLayout<UInt16>.size, 1, stream) == 1,
                  encrypted.withUnsafeBytes({ fwrite($0.baseAddress, 1, encrypted.count, stream) }) == encrypted.count else { throw failure(path, "Cannot write preflight manifest") }
            written += 1
        }
        func rewind(path: String) throws {
            guard fflush(stream) == 0, fseek(stream, 0, SEEK_SET) == 0 else { throw failure(path, "Cannot read preflight manifest") }
            reading = 0
        }
        func read(path: String) throws -> (String, stat) {
            var length: UInt16 = 0, value = stat()
            guard reading < written, fread(&length, MemoryLayout<UInt16>.size, 1, stream) == 1, length > 0, length <= 1024 else { throw Failure(path, "Invalid preflight manifest") }
            var encrypted = Data(count: Int(length))
            let count = encrypted.count
            guard encrypted.withUnsafeMutableBytes({ fread($0.baseAddress, 1, count, stream) }) == count else { throw Failure(path, "Incomplete preflight record") }
            let payload = try AES.GCM.open(AES.GCM.SealedBox(combined: encrypted), using: key, authenticating: ordinal(reading))
            guard payload.count >= MemoryLayout<stat>.size, payload.count <= MemoryLayout<stat>.size + Int(NAME_MAX) else { throw Failure(path, "Invalid preflight record") }
            withUnsafeMutableBytes(of: &value) { _ = payload.prefix(MemoryLayout<stat>.size).copyBytes(to: $0) }
            guard let name = String(data: payload.dropFirst(MemoryLayout<stat>.size), encoding: .utf8),
                  !name.contains("/"), !name.utf8.contains(0), name != ".", name != ".." else { throw Failure(path, "Invalid preflight entry") }
            reading += 1
            return (name, value)
        }
    }

    fileprivate final class Prepared {
        let target: Target
        let permitsSymbolicLinks: Bool
        let authorizedUID: uid_t?
        let parts: [String]
        var ancestors: [Descriptor] = []
        let manifest: Manifest
        var top: Descriptor?
        var mount = ""
        var bytes: UInt64 = 0
        var parent: Int32 { ancestors.last!.fd }
        var leaf: String { parts.last! }

        init(_ target: Target, home: String, permitsSymbolicLinks: Bool, authorizedUID: uid_t? = nil) throws {
            self.target = target
            self.permitsSymbolicLinks = permitsSymbolicLinks
            self.authorizedUID = authorizedUID
            parts = target.path.split(separator: "/").map(String.init)
            manifest = try Manifest(path: target.path)
            guard parts.count <= maxDepth else { throw Failure(target.path, "Ancestor depth limit exceeded") }
            ancestors.append(try Descriptor(open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC), path: "/"))
            var path = ""
            for part in parts.dropLast() {
                path += "/" + part
                let next = try Descriptor(openat(parent, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC), path: path)
                guard next.initial.st_uid == 0 || next.initial.st_uid == (authorizedUID ?? getuid()) else { throw Failure(path, "Unsafe ancestor owner") }
                if path == home || path.hasPrefix(home + "/") {
                    guard next.initial.st_uid == (authorizedUID ?? getuid()), next.initial.st_flags & protectedFlags == 0 else { throw Failure(path, "Unsafe app-data ancestor") }
                }
                ancestors.append(next)
            }
            let original = try named(parent, leaf, path: target.path)
            let linkFlag = permitsSymbolicLinks && original.st_mode & S_IFMT == S_IFLNK ? O_SYMLINK : O_NOFOLLOW
            let directory = try Descriptor(openat(parent, leaf, O_RDONLY | linkFlag | O_CLOEXEC | O_NONBLOCK | (authorizedUID == nil ? O_DIRECTORY : 0)), path: target.path)
            try safe(directory.initial, device: ancestors.last!.initial.st_dev, path: target.path,
                     permitsSymbolicLinks: permitsSymbolicLinks, authorizedUID: authorizedUID)
            mount = try local(parent, path: target.path)
            guard try local(directory.fd, path: target.path) == mount else { throw Failure(target.path, "Directory is a mount point") }
            guard target.expected.matches(directory.initial) else { throw Failure(target.path, "Directory changed since review") }
            top = directory
        }
        func validate() throws {
            guard geteuid() == getuid(),
                  authorizedUID.map({ getuid() == 0 || getuid() == $0 }) ?? (getuid() != 0),
                  let top else { throw Failure(target.path, "Removal credentials changed") }
            for index in 1..<ancestors.count {
                let value = try named(ancestors[index - 1].fd, parts[index - 1], path: target.path)
                guard sameObject(value, ancestors[index].initial) else { throw Failure(target.path, "Ancestor changed during review") }
            }
            let value = try named(parent, leaf, path: target.path)
            guard unchanged(value, top.initial), target.expected.matches(value) else { throw Failure(target.path, "Directory changed since preflight") }
        }
        func preflight(entries: inout Int) throws {
            try walk(parent, leaf, path: target.path, depth: 0, entries: &entries)
            try manifest.rewind(path: target.path)
        }
        func walk(_ parent: Int32, _ name: String, path: String, depth: Int, entries: inout Int) throws {
            entries += 1
            guard depth <= maxDepth, entries <= maxEntries, path.utf8.count < Int(PATH_MAX) else { throw Failure(path, "Directory preflight resource limit exceeded") }
            let value = try named(parent, name, path: path)
            try safe(value, device: top!.initial.st_dev, path: path, permitsSymbolicLinks: permitsSymbolicLinks, authorizedUID: authorizedUID)
            bytes += UInt64(max(value.st_blocks, 0)) * 512
            try manifest.write(name, value, path: path)
            guard value.st_mode & S_IFMT == S_IFDIR else { return }
            let directory = try Descriptor(openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC), path: path)
            guard unchanged(directory.initial, value) else { throw Failure(path, "Directory changed during preflight") }
            guard try local(directory.fd, path: path) == mount else { throw Failure(path, "Descendant is a mount point") }
            let copy = fcntl(directory.fd, F_DUPFD_CLOEXEC, 0)
            guard copy >= 0 else { throw failure(path, "Directory descriptor limit exceeded") }
            guard let stream = fdopendir(copy) else { close(copy); throw failure(path, "Cannot enumerate directory") }
            defer { closedir(stream) }
            while true {
                errno = 0
                guard let entry = readdir(stream) else {
                    guard errno == 0 else { throw failure(path, "Incomplete directory enumeration") }
                    break
                }
                let child = withUnsafePointer(to: entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(validatingCString: $0) }
                }
                guard let child else { throw Failure(path, "Unrepresentable directory entry") }
                if child == "." || child == ".." { continue }
                try walk(directory.fd, child, path: path + "/" + child, depth: depth + 1, entries: &entries)
            }
            var after = stat()
            guard fstat(directory.fd, &after) == 0, unchanged(value, after) else { throw Failure(path, "Directory changed during preflight") }
            try manifest.write("", path: path)
        }

        func trash() throws {
            try validate()
            var coordinationError: NSError?, removalError: Error?
            NSFileCoordinator().coordinate(writingItemAt: URL(fileURLWithPath: target.path), options: .forMoving, error: &coordinationError) { url in
                do {
                    guard url.path == target.path,
                          URL(fileURLWithPath: target.path).resolvingSymlinksInPath().path == target.path else {
                        throw Failure(target.path, "Directory location changed before Trash")
                    }
                    try validate()
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                } catch { removalError = error }
            }
            if let coordinationError { throw coordinationError }
            if let removalError { throw removalError }
        }

        func remove() throws {
            try validate()
            let stageName = ".macspace-directory-" + UUID().uuidString
            let stagePath = (target.path as NSString).deletingLastPathComponent + "/" + stageName
            guard mkdirat(parent, stageName, 0o700) == 0 else { throw failure(target.path, "Cannot create private removal directory") }
            let stage = try Descriptor(openat(parent, stageName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC), path: stagePath)
            guard stage.initial.st_uid == getuid(), stage.initial.st_mode & 0o777 == 0o700,
                  stage.initial.st_dev == top!.initial.st_dev else { throw Failure(target.path, "Unsafe removal directory", preservedPath: stagePath) }
            defer {
                // Empty-only cleanup; never recursively remove a failed staging area.
                if let current = try? named(parent, stageName, path: stagePath), sameObject(current, stage.initial) {
                    _ = unlinkat(parent, stageName, AT_REMOVEDIR)
                }
            }
            try validate()
            let (name, value) = try manifest.read(path: target.path)
            guard name == leaf, unchanged(value, top!.initial) else { throw Failure(target.path, "Invalid top-level preflight entry") }
            try erase(parent, name, value, path: target.path, stage: stage.fd, stagePath: stagePath, depth: 0)
        }
        func erase(_ source: Int32, _ name: String, _ expected: stat, path: String,
                   stage: Int32, stagePath: String, depth: Int) throws {
            guard depth <= maxDepth else { throw Failure(path, "Removal depth limit exceeded") }
            let current = try named(source, name, path: path)
            try safe(current, device: top!.initial.st_dev, path: path, permitsSymbolicLinks: permitsSymbolicLinks, authorizedUID: authorizedUID)
            guard unchanged(current, expected) else { throw Failure(path, "Entry changed since preflight") }
            let slot = UUID().uuidString
            guard renameatx_np(source, name, stage, slot, UInt32(RENAME_EXCL)) == 0 else { throw failure(path, "Cannot guard directory entry") }
            let preserved = stagePath + "/" + slot
            do {
                let moved = try named(stage, slot, path: path)
                guard unchanged(moved, expected, afterRename: true) else { throw Failure(path, "Entry replaced during guarded rename") }
                if expected.st_mode & S_IFMT == S_IFDIR {
                    let directory = try Descriptor(openat(stage, slot, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC), path: path)
                    guard unchanged(directory.initial, moved) else { throw Failure(path, "Staged directory changed") }
                    while true {
                        let (child, value) = try manifest.read(path: path)
                        if child.isEmpty { break }
                        try erase(directory.fd, child, value, path: path + "/" + child, stage: stage, stagePath: stagePath, depth: depth + 1)
                    }
                    let final = try named(stage, slot, path: path)
                    try safe(final, device: expected.st_dev, path: path, permitsSymbolicLinks: permitsSymbolicLinks, authorizedUID: authorizedUID)
                    guard sameObject(final, moved) else { throw Failure(path, "Staged directory replaced") }
                    // Unexpected new children make rmdir fail; they are never enumerated/deleted here.
                    guard unlinkat(stage, slot, AT_REMOVEDIR) == 0 else { throw failure(path, "Cannot remove directory; remaining data preserved") }
                } else {
                    // Symlinks in an explicitly selected personal folder are directory entries only:
                    // rename/unlink never opens or follows their destinations, including links to / or outside the tree.
                    let final = try named(stage, slot, path: path)
                    try safe(final, device: expected.st_dev, path: path, permitsSymbolicLinks: permitsSymbolicLinks, authorizedUID: authorizedUID)
                    guard unchanged(final, moved) else { throw Failure(path, "Staged file changed") }
                    guard unlinkat(stage, slot, 0) == 0 else { throw failure(path, "Cannot unlink reviewed file") }
                }
            } catch {
                // EXCL preserves any new entry at the original name. A failed restore stays visible in Failure.
                if renameatx_np(stage, slot, source, name, UInt32(RENAME_EXCL)) != 0 {
                    throw Failure(path, error.localizedDescription, preservedPath: preserved)
                }
                throw error
            }
        }
    }
}
