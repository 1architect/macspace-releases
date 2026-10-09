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

    /// True the first time a family is seen.
    func claim(_ family: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return seen.insert(family).inserted
    }
}

public struct FileTreeSizer: Sendable {
    /// Also adds up the files flagged purgeable (`FileTreeSize.purgeableBytes`): one more system call per file.
    public let countsPurgeable: Bool
    /// Counts each APFS clone family's shared blocks once across every tree sized with this ledger.
    public let clones: CloneLedger?

    public init(countsPurgeable: Bool = false, clones: CloneLedger? = nil) {
        self.countsPurgeable = countsPurgeable
        self.clones = clones
    }

    /// A file's clone family, the bytes only it holds, and its extended flags. nil when they cannot be read.
    static func extendedAttributes(_ path: String) -> (family: UInt64, privateBytes: UInt64, flags: UInt64)? {
        var list = attrlist(bitmapcount: u_short(ATTR_BIT_MAP_COUNT), reserved: 0, commonattr: 0, volattr: 0, dirattr: 0, fileattr: 0,
                            forkattr: attrgroup_t(ATTR_CMNEXT_PRIVATESIZE | ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_EXT_FLAGS))
        var buffer = [UInt8](repeating: 0, count: 32)
        let result = buffer.withUnsafeMutableBytes { getattrlist(path, &list, $0.baseAddress, $0.count, UInt32(FSOPT_NOFOLLOW | FSOPT_ATTR_CMN_EXTENDED)) }
        guard result == 0 else { return nil }
        // The length, then the extended attributes in bit order: private size, clone id, extended flags.
        return buffer.withUnsafeBytes {
            (family: $0.loadUnaligned(fromByteOffset: 12, as: UInt64.self),
             privateBytes: UInt64(max($0.loadUnaligned(fromByteOffset: 4, as: Int64.self), 0)),
             flags: $0.loadUnaligned(fromByteOffset: 20, as: UInt64.self))
        }
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

    private var sizingKeys: Set<URLResourceKey> {
        [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .fileAllocatedSizeKey,
            .totalFileSizeKey,
            .totalFileAllocatedSizeKey,
            .volumeIdentifierKey
        ]
    }

    /// Descriptive filesystem sizing only. This deliberately does not claim unique APFS block ownership.
    /// Descendants mounted from another filesystem are skipped to avoid obvious double counting.
    public func size(at url: URL) -> FileTreeSize? {
        do {
            let rootValues = try url.resourceValues(forKeys: sizingKeys)
            if rootValues.isSymbolicLink == true {
                return nil
            }

            if rootValues.isRegularFile == true {
                return FileTreeSize(
                    logicalBytes: logicalSize(from: rootValues) ?? 0,
                    allocatedBytesEstimate: allocatedSize(from: rootValues)
                )
            }

            guard rootValues.isDirectory == true else {
                return FileTreeSize(
                    logicalBytes: logicalSize(from: rootValues) ?? 0,
                    allocatedBytesEstimate: allocatedSize(from: rootValues)
                )
            }

            let rootVolumeID = rootValues.volumeIdentifier.map { String(describing: $0) }
            // The enumerator reports a folder it cannot open through this handler and goes on; the count says the sizes are short.
            let errors = ErrorCount()
            guard let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: Array(sizingKeys),
                options: [],
                errorHandler: { _, _ in errors.value += 1; return true }
            ) else { return nil }

            var logical: UInt64 = 0
            var allocated: UInt64 = 0
            var purgeable: UInt64 = 0
            var sawAllocated = false

            for case let item as URL in enumerator {
                // One pool per file: a tree of a million files otherwise keeps every URL and attribute it touched until the end.
                autoreleasepool {
                    guard let resource = try? item.resourceValues(forKeys: sizingKeys) else { return }
                    if resource.isSymbolicLink == true { return }

                    if let rootVolumeID,
                       let itemVolumeID = resource.volumeIdentifier.map({ String(describing: $0) }),
                       itemVolumeID != rootVolumeID {
                        enumerator.skipDescendants()
                        return
                    }

                    guard resource.isRegularFile == true else { return }
                    logical += logicalSize(from: resource) ?? 0
                    if var value = allocatedSize(from: resource) {
                        if countsPurgeable || clones != nil, value > 0, let extended = Self.extendedAttributes(item.path) {
                            // A later member of a clone family adds only what it does not share.
                            if let clones, extended.family != 0, !clones.claim(extended.family) { value = min(value, extended.privateBytes) }
                            if countsPurgeable, extended.flags & UInt64(EF_IS_PURGEABLE) != 0 { purgeable += value }
                        }
                        allocated += value
                        sawAllocated = true
                    }
                }
            }

            return FileTreeSize(
                logicalBytes: logical,
                allocatedBytesEstimate: sawAllocated ? allocated : nil,
                unreadableFolders: errors.value,
                purgeableBytes: purgeable
            )
        } catch {
            return nil
        }
    }

    private final class ErrorCount: @unchecked Sendable {
        var value = 0
    }

    private func logicalSize(from values: URLResourceValues) -> UInt64? {
        let value = values.totalFileSize ?? values.fileSize
        return value.map { UInt64(max(0, $0)) }
    }

    private func allocatedSize(from values: URLResourceValues) -> UInt64? {
        let value = values.totalFileAllocatedSize ?? values.fileAllocatedSize
        return value.map { UInt64(max(0, $0)) }
    }
}
