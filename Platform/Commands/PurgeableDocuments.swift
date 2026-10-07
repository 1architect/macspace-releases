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
        var folders: [String: Folder] = [:]
        var bytes: UInt64 = 0
        var files = 0
        let walked = walk(rootPath, timeLimit: timeLimit) { path, allocated in
            bytes += allocated
            files += 1
            let relative = path.dropFirst(rootPath.count).drop { $0 == "/" }
            let top = relative.contains("/") ? String(relative.prefix { $0 != "/" }) : "(top level)"
            folders[top, default: Folder(name: top, bytes: 0, files: 0)].bytes += allocated
            folders[top, default: Folder(name: top, bytes: 0, files: 0)].files += 1
        }
        guard walked else { return nil }
        return Source(name: name, path: rootPath, bytes: bytes, files: files, folders: folders.values.sorted { $0.bytes > $1.bytes })
    }

    /// Calls `visit` with each file under `rootPath` that APFS flags purgeable and its allocated size, until `timeLimit` seconds have
    /// passed. False when the folder cannot be read.
    static func walk(_ rootPath: String, timeLimit: TimeInterval, _ visit: (String, UInt64) -> Void) -> Bool {
        guard FileManager.default.fileExists(atPath: rootPath), let rootCopy = strdup(rootPath) else { return false }
        defer { free(rootCopy) }
        var paths: [UnsafeMutablePointer<CChar>?] = [rootCopy, nil]
        guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil) else { return false }
        defer { fts_close(fts) }
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
            visit(String(cString: cPath), allocated)
        }
        return true
    }

    /// Forgets the last scan, after downloads were removed.
    public static func forget() {
        lock.lock()
        cached = nil
        lock.unlock()
    }

    /// What removing a cloud folder's downloads did.
    public struct Removal: Sendable, Equatable {
        /// Files whose local copy was removed, and their size on disk.
        public var files = 0
        public var bytes: UInt64 = 0
        /// Files left as they are: not uploaded yet, still uploading, in conflict, or refused by the cloud app.
        public var kept = 0
        /// The first few reasons a file was refused.
        public var errors: [String] = []

        public init() {}
    }

    /// The folders whose downloads may be removed: a File Provider service's folder, or iCloud Drive.
    public static func isCloudFolder(_ path: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        let cloudStorage = home.appendingPathComponent("Library/CloudStorage").path + "/"
        let iCloudDrive = home.appendingPathComponent("Library/Mobile Documents").path
        guard !standardized.contains("/../") else { return false }
        if standardized == iCloudDrive { return true }
        // One folder directly in CloudStorage: a service's own folder, not a folder inside it.
        return standardized.hasPrefix(cloudStorage) && !standardized.dropFirst(cloudStorage.count).contains("/")
            && standardized.count > cloudStorage.count
    }

    /// How many files are asked at once. One at a time took 0.1 s a file in OneDrive (8,065 files, about 13 minutes); each request
    /// mostly waits on the cloud app, so several go together.
    static let concurrentRemovals = 8

    /// Removes the local copies of the files in a cloud folder that are already in the cloud, as Finder's Free Up Space does, with
    /// the API made for it (`FileManager.evictUbiquitousItem`), which iCloud Drive and every File Provider app (OneDrive, Google
    /// Drive, Dropbox) answer. Only files macOS itself counts as purgeable: a file set to Always Keep on This Device is not, and each
    /// must also be uploaded, not uploading and without conflicts. The files stay in the cloud and download again when opened.
    /// The largest go first, so the space comes back early; `progress` gets the files done, their number, and the bytes removed.
    public static func removeDownloads(in root: URL, progress: @escaping @Sendable (Int, Int, UInt64) -> Void = { _, _, _ in }) -> Removal {
        guard isCloudFolder(root.path) else { return Removal() }
        var candidates: [(path: String, bytes: UInt64)] = []
        _ = walk(root.path, timeLimit: 120) { candidates.append(($0, $1)) }
        candidates.sort { $0.bytes > $1.bytes }
        let total = candidates.count
        let state = RemovalState()
        progress(0, total, 0)
        DispatchQueue.concurrentPerform(iterations: min(concurrentRemovals, max(total, 1))) { worker in
            for index in stride(from: worker, to: total, by: concurrentRemovals) {
                let candidate = candidates[index]
                let url = URL(fileURLWithPath: candidate.path)
                let values = try? url.resourceValues(forKeys: [.ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey, .ubiquitousItemHasUnresolvedConflictsKey])
                let outcome: Result<UInt64, Error>?
                if values?.ubiquitousItemIsUploaded == true, values?.ubiquitousItemIsUploading != true, values?.ubiquitousItemHasUnresolvedConflicts != true {
                    do { try FileManager.default.evictUbiquitousItem(at: url); outcome = .success(candidate.bytes) }
                    catch { outcome = .failure(error) }
                } else {
                    outcome = nil
                }
                let (done, bytes) = state.record(outcome, name: url.lastPathComponent)
                if done % 25 == 0 || done == total { progress(done, total, bytes) }
            }
        }
        return state.removal
    }
}

/// The tally of a removal, shared by the requests running together.
private final class RemovalState: @unchecked Sendable {
    private let lock = NSLock()
    private var current = PurgeableDocuments.Removal()
    private var done = 0

    /// Counts one file: removed (its size), refused (the error) or skipped (nil). Returns the files done and the bytes removed so far.
    func record(_ outcome: Result<UInt64, Error>?, name: String) -> (Int, UInt64) {
        lock.lock()
        defer { lock.unlock() }
        done += 1
        switch outcome {
        case let .success(bytes)?:
            current.files += 1
            current.bytes += bytes
        case let .failure(error)?:
            current.kept += 1
            if current.errors.count < 3 { current.errors.append("\(name): \(error.localizedDescription)") }
        case nil:
            current.kept += 1
        }
        return (done, current.bytes)
    }

    var removal: PurgeableDocuments.Removal {
        lock.lock()
        defer { lock.unlock() }
        return current
    }
}

/// Removals of cloud downloads running in the background, one per cloud folder at most: the page stays usable while one runs and
/// shows how far it is.
public final class CloudDownloadRemovals: @unchecked Sendable {
    public static let shared = CloudDownloadRemovals()

    public struct Progress: Sendable, Equatable {
        public var done: Int
        public var total: Int
        public var bytes: UInt64

        public init(done: Int, total: Int, bytes: UInt64) {
            self.done = done
            self.total = total
            self.bytes = bytes
        }

        /// 0...1; 0 while the files are still being listed.
        public var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
    }

    private let lock = NSLock()
    private var running: [String: Progress] = [:]

    /// The removals running now, by cloud folder.
    public func current() -> [String: Progress] {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    /// Starts removing the downloads in `root` in the background, unless that folder's removal is already running (then false).
    /// `finished` gets what was removed and the space the volume gained.
    @discardableResult
    public func start(_ root: URL, finished: @escaping @Sendable (PurgeableDocuments.Removal, UInt64) -> Void) -> Bool {
        let path = root.path
        lock.lock()
        guard running[path] == nil else { lock.unlock(); return false }
        running[path] = Progress(done: 0, total: 0, bytes: 0)
        lock.unlock()
        DispatchQueue.global(qos: .utility).async {
            let before = DataVolume.freeBytes()
            let removal = PurgeableDocuments.removeDownloads(in: root) { [weak self] done, total, bytes in
                guard let self else { return }
                self.lock.lock()
                self.running[path] = Progress(done: done, total: total, bytes: bytes)
                self.lock.unlock()
            }
            PurgeableDocuments.forget()
            var freed: UInt64 = 0
            if let before, let after = DataVolume.settledFreeBytes(), after > before { freed = after - before }
            self.lock.lock()
            self.running[path] = nil
            self.lock.unlock()
            finished(removal, freed)
        }
        return true
    }
}
