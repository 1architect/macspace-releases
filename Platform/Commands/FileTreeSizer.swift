import Foundation

public struct FileTreeSize: Sendable, Equatable {
    public let logicalBytes: UInt64
    public let allocatedBytesEstimate: UInt64?
    /// Folders inside the tree that could not be listed (no permission, SIP). The sizes then leave them out: a tree with a folder it
    /// could not open is not known to be empty.
    public let unreadableFolders: Int
    /// Of the allocated size, what files macOS may delete by itself take (flagged purgeable, `EF_IS_PURGEABLE`): System Settings
    /// counts them as free space. Counted only when asked (`FileTreeSizer(countsPurgeable:)`), 0 otherwise.
    public let purgeableBytes: UInt64

    public init(logicalBytes: UInt64, allocatedBytesEstimate: UInt64?, unreadableFolders: Int = 0, purgeableBytes: UInt64 = 0) {
        self.logicalBytes = logicalBytes
        self.allocatedBytesEstimate = allocatedBytesEstimate
        self.unreadableFolders = unreadableFolders
        self.purgeableBytes = purgeableBytes
    }

    /// The best figure for what the tree takes on disk.
    public var bytes: UInt64 { allocatedBytesEstimate ?? logicalBytes }
}

/// APFS clone families already counted, shared by every tree one scan sizes. A cloned file's blocks are stored once however many
/// files share them; System Settings counts the disk's real use, so a per-file count overstated System Data (0.47 GB in
/// `~/Library/Application Support` alone, measured 2026-10-06). The first file of a family counts in full, later ones only the bytes
/// they do not share (`ATTR_CMNEXT_PRIVATESIZE`).
public final class CloneLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var seen = Set<UInt64>()

    public init() {}

    private var links = Set<UInt64>()

    /// True the first time a family is seen.
    func claim(_ family: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return seen.insert(family).inserted
    }

    /// True the first time a hard-linked file (by its inode) is seen: its blocks are stored once however many paths reach it
    /// (`HardLinks`).
    func claimLink(_ inode: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return links.insert(inode).inserted
    }
}

/// A file with more than one hard link is stored once. Counted once per path, `~/Library/Metadata/CoreSpotlight` alone came to
/// 1.49 GB more than it takes (measured 2026-10-12, 2.14 GB over the whole Data volume), which put System Data's listed items above
/// System Settings' figure.
enum HardLinks {
    /// The file's inode when it has more than one link; nil for an ordinary file (one link), which needs no bookkeeping.
    static func inode(_ path: String) -> UInt64? {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_nlink > 1 else { return nil }
        return UInt64(info.st_ino)
    }
}

public struct FileTreeSizer: Sendable {
    /// Also adds up the files flagged purgeable (`FileTreeSize.purgeableBytes`): one more system call per file.
    public let countsPurgeable: Bool
    /// Counts each APFS clone family's shared blocks once across every tree sized with this ledger.
    public let clones: CloneLedger?

    /// Threads idle elsewhere in the scan that may help with a large tree (`DirectoryWalk`); nil walks each tree on one thread.
    public let pool: ScanPool?

    /// Opens no folder through a link anywhere in its path (`O_NOFOLLOW_ANY`), for root measuring paths a caller named.
    public let refusesLinks: Bool

    public init(countsPurgeable: Bool = false, clones: CloneLedger? = nil, pool: ScanPool? = nil, refusesLinks: Bool = false) {
        self.countsPurgeable = countsPurgeable
        self.clones = clones
        self.pool = pool
        self.refusesLinks = refusesLinks
    }

    /// Whether APFS flags the file purgeable: macOS may delete it when space runs low.
    public static func isPurgeable(_ path: String) -> Bool {
        var list = attrlist(bitmapcount: u_short(ATTR_BIT_MAP_COUNT), reserved: 0, commonattr: 0, volattr: 0, dirattr: 0, fileattr: 0,
                            forkattr: attrgroup_t(ATTR_CMNEXT_EXT_FLAGS))
        var buffer = [UInt8](repeating: 0, count: 16)
        let result = buffer.withUnsafeMutableBytes { getattrlist(path, &list, $0.baseAddress, $0.count, UInt32(FSOPT_NOFOLLOW | FSOPT_ATTR_CMN_EXTENDED)) }
        guard result == 0 else { return false }
        // The length, then the extended flags.
        let flags = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt64.self) }
        return flags & UInt64(EF_IS_PURGEABLE) != 0
    }

    /// What deleting the tree would free: the blocks of its files that no other file shares (`ATTR_CMNEXT_PRIVATESIZE`), each
    /// hard-linked file once. A code-signing copy of an app is an APFS clone of it and shares every block until the app is updated;
    /// then the copy of the older version holds blocks of its own. Measured on 26B5101f (2026-10-13): two copies of SketchUp's apps,
    /// 3.39 GB by size, held 0.05 GB of their own. nil when the tree cannot be read.
    public static func unsharedBytes(at path: String) -> UInt64? {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
        let links = CloneLedger()
        let walk = DirectoryWalk.walk(path, extended: true, initial: UInt64(0)) { total, path, entry in
            if entry.isDirectory { return entry.isDataless ? .skip : .descend }
            guard entry.isRegularFile else { return .skip }
            if entry.linkCount > 1, let inode = HardLinks.inode(path()), !links.claimLink(inode) { return .skip }
            total += min(entry.allocatedBytes, entry.privateBytes)
            return .skip
        }
        return walk.state
    }

    /// Descriptive filesystem sizing only. This deliberately does not claim unique APFS block ownership.
    /// Descendants mounted from another filesystem are skipped to avoid obvious double counting, and so are folders still only in
    /// the cloud (`SF_DATALESS`): listing them would make the cloud app fetch them, and what they hold takes no space here.
    public func size(at url: URL) -> FileTreeSize? {
        let root = url.path
        var info = stat()
        guard lstat(root, &info) == 0 else { return nil }
        switch info.st_mode & S_IFMT {
        case S_IFLNK:
            return nil
        case S_IFDIR:
            break
        default:
            // A single file: its sizes, as the folder walk reads them.
            guard let file = try? url.resourceValues(forKeys: [.fileSizeKey, .fileAllocatedSizeKey, .totalFileSizeKey, .totalFileAllocatedSizeKey]) else { return nil }
            return FileTreeSize(logicalBytes: UInt64(max(0, file.totalFileSize ?? file.fileSize ?? 0)),
                                allocatedBytesEstimate: (file.totalFileAllocatedSize ?? file.fileAllocatedSize).map { UInt64(max(0, $0)) })
        }

        struct Sums { var logical: UInt64 = 0, allocated: UInt64 = 0, purgeable: UInt64 = 0, sawFile = false }
        // Hard-linked files met in this tree; across trees, the ledger's.
        let links = clones ?? CloneLedger()
        let clones = clones
        let countsPurgeable = countsPurgeable
        let extended = countsPurgeable || clones != nil
        let walk = DirectoryWalk.walk(root, extended: extended, pool: pool, refusesLinks: refusesLinks, makeState: { Sums() }) { sums, path, entry in
            if entry.isDirectory { return entry.isDataless ? .skip : .descend }
            guard entry.isRegularFile else { return .skip }
            // A file reached by several hard links counts at its first path only.
            if entry.linkCount > 1, let inode = HardLinks.inode(path()), !links.claimLink(inode) { return .skip }
            sums.sawFile = true
            sums.logical += entry.logicalBytes
            var value = entry.allocatedBytes
            if extended, value > 0 {
                // A later member of a clone family adds only what it does not share.
                if let clones, entry.cloneFamily != 0, !clones.claim(entry.cloneFamily) { value = min(value, entry.privateBytes) }
                if countsPurgeable, entry.extendedFlags & UInt64(EF_IS_PURGEABLE) != 0 { sums.purgeable += value }
            }
            sums.allocated += value
            return .skip
        }
        let total = walk.states.reduce(into: Sums()) { total, part in
            total.logical += part.logical
            total.allocated += part.allocated
            total.purgeable += part.purgeable
            total.sawFile = total.sawFile || part.sawFile
        }
        return FileTreeSize(logicalBytes: total.logical, allocatedBytesEstimate: total.sawFile ? total.allocated : nil,
                            unreadableFolders: walk.unreadable, purgeableBytes: total.purgeable)
    }
}
