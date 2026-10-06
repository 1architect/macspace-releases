import Darwin
import Foundation

/// The documents macOS counts as purgeable (CacheDelete's `com.apple.fspurgeable_document`), found by the flag APFS keeps on each
/// file (`EF_IS_PURGEABLE`). Cloud apps built on File Provider (OneDrive, Google Drive, Dropbox) and iCloud Drive set it on the files
/// they downloaded and keep in the cloud: macOS may delete the local copy when space runs low, and the file downloads again when it
/// is opened. Measured on 26B5091g (2026-10-06): 22.94 GB flagged in OneDrive's folder against 21.15 GB reported by CacheDelete, and
/// nothing flagged anywhere else in the home folder.
public enum PurgeableDocuments {
    /// One cloud folder holding purgeable documents.
    public struct Source: Sendable, Equatable {
        /// What the cloud service is called, e.g. "OneDrive (Pessoal)".
        public var name: String
        public var path: String
        public var bytes: UInt64
        public var files: Int
        /// Its top-level folders holding purgeable files, largest first.
        public var folders: [Folder]

        public init(name: String, path: String, bytes: UInt64, files: Int, folders: [Folder]) {
            self.name = name
            self.path = path
            self.bytes = bytes
            self.files = files
            self.folders = folders
        }
    }

    public struct Folder: Sendable, Equatable {
        public var name: String
        public var bytes: UInt64
        public var files: Int

        public init(name: String, bytes: UInt64, files: Int) {
            self.name = name
            self.bytes = bytes
            self.files = files
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: (at: Date, sources: [Source])?

    /// `scan`, at most once every `maxAge` seconds: a cloud folder can hold millions of files.
    public static func scan(maxAge: TimeInterval, now: Date = Date()) -> [Source] {
        lock.lock()
        if let cached, now.timeIntervalSince(cached.at) < maxAge { lock.unlock(); return cached.sources }
        lock.unlock()
        let sources = scan()
        lock.lock()
        cached = (now, sources)
        lock.unlock()
        return sources
    }

    /// How long one cloud folder may take; past it the folder's figure is what was found so far.
    static let timeLimit: TimeInterval = 30

    /// The cloud folders of `home` (every File Provider service's `Library/CloudStorage/*`, whatever it is, and iCloud Drive), each
    /// with what is purgeable in it; those with nothing purgeable are left out. Largest first.
    public static func scan(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [Source] {
        let cloudStorage = home.appendingPathComponent("Library/CloudStorage")
        var roots = ((try? FileManager.default.contentsOfDirectory(atPath: cloudStorage.path)) ?? [])
            .filter { !$0.hasPrefix(".") }.map { (name: displayName($0), url: cloudStorage.appendingPathComponent($0)) }
        roots.append((name: "iCloud Drive", url: home.appendingPathComponent("Library/Mobile Documents")))
        return roots.compactMap { scan($0.url, name: $0.name) }.filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }
    }

    /// "OneDrive-Pessoal" -> "OneDrive (Pessoal)": File Provider names the folder after the service and the account.
    public static func displayName(_ folder: String) -> String {
        guard let dash = folder.firstIndex(of: "-") else { return folder }
        return "\(folder[..<dash]) (\(folder[folder.index(after: dash)...]))"
    }

    /// What is purgeable under one folder, by its top-level folders. nil when it cannot be read.
    static func scan(_ root: URL, name: String) -> Source? {
        let rootPath = root.path
        guard FileManager.default.fileExists(atPath: rootPath), let rootCopy = strdup(rootPath) else { return nil }
        defer { free(rootCopy) }
        var paths: [UnsafeMutablePointer<CChar>?] = [rootCopy, nil]
        guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil) else { return nil }
        defer { fts_close(fts) }
        var folders: [String: Folder] = [:]
        var bytes: UInt64 = 0
        var files = 0
        var list = attrlist(bitmapcount: u_short(ATTR_BIT_MAP_COUNT), reserved: 0, commonattr: 0, volattr: 0, dirattr: 0,
                            fileattr: attrgroup_t(ATTR_FILE_ALLOCSIZE), forkattr: attrgroup_t(ATTR_CMNEXT_EXT_FLAGS))
        var buffer = [UInt8](repeating: 0, count: 32)
        let started = Date()
        while let entry = fts_read(fts) {
            if Date().timeIntervalSince(started) > timeLimit { break }
            // A folder still only in the cloud (dataless) holds nothing on this Mac; listing it would make the provider fetch it.
            if Int32(entry.pointee.fts_info) == FTS_D, let stat = entry.pointee.fts_statp, stat.pointee.st_flags & UInt32(SF_DATALESS) != 0 {
                fts_set(fts, entry, FTS_SKIP)
                continue
            }
            guard Int32(entry.pointee.fts_info) == FTS_F, let cPath = entry.pointee.fts_path else { continue }
            // File attributes come before the extended common ones: length, then the allocated size, then the extended flags.
            let result = buffer.withUnsafeMutableBytes { getattrlist(cPath, &list, $0.baseAddress, $0.count, UInt32(FSOPT_NOFOLLOW | FSOPT_ATTR_CMN_EXTENDED)) }
            guard result == 0 else { continue }
            let allocated = buffer.withUnsafeBytes { UInt64(max($0.loadUnaligned(fromByteOffset: 4, as: Int64.self), 0)) }
            let flags = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 12, as: UInt64.self) }
            guard flags & UInt64(EF_IS_PURGEABLE) != 0 else { continue }
            bytes += allocated
            files += 1
            let relative = String(cString: cPath).dropFirst(rootPath.count).drop { $0 == "/" }
            let top = relative.contains("/") ? String(relative.prefix { $0 != "/" }) : "(top level)"
            folders[top, default: Folder(name: top, bytes: 0, files: 0)].bytes += allocated
            folders[top, default: Folder(name: top, bytes: 0, files: 0)].files += 1
        }
        return Source(name: name, path: rootPath, bytes: bytes, files: files, folders: folders.values.sorted { $0.bytes > $1.bytes })
    }
}
