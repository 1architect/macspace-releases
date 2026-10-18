import Darwin
import Foundation

/// Uploaded local cloud copies that can be offered for explicit eviction. APFS's purgeable flag and CacheDelete's pressure-based
/// estimate are not eligibility checks: OneDrive can have uploaded, unpinned local files without that flag.
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
    nonisolated(unsafe) private static var generation = 0

    /// `scan`, at most once every `maxAge` seconds: a cloud folder can hold millions of files.
    public static func scan(maxAge: TimeInterval, now: Date = Date(), progress: @escaping @Sendable (Double) -> Void = { _ in }) -> [Source] {
        lock.lock()
        if let cached, now.timeIntervalSince(cached.at) < maxAge { lock.unlock(); progress(1); return cached.sources }
        let started = generation
        lock.unlock()
        let sources = scan(progress: progress)
        lock.lock()
        if started == generation { cached = (now, sources) }
        lock.unlock()
        return sources
    }

    /// Reconcile only the affected provider after eviction. Other providers keep their measurements and cache age.
    public static func refreshSource(_ root: URL) -> Source? {
        guard isCloudFolder(root.path) else { return nil }
        lock.lock()
        let name = cached?.sources.first { $0.path == root.path }?.name ?? displayName(root.lastPathComponent)
        lock.unlock()
        guard let source = scan(root, name: name) else { return nil }
        lock.lock()
        generation += 1
        if cached != nil {
            cached?.sources.removeAll { $0.path == root.path }
            if source.bytes > 0 { cached?.sources.append(source) }
            cached?.sources.sort { $0.bytes > $1.bytes }
        }
        lock.unlock()
        return source
    }

    /// How long one cloud folder may take; past it the folder's figure is what was found so far.
    static let timeLimit: TimeInterval = 30

    /// The cloud folders of `home` (every File Provider service's `Library/CloudStorage/*`, whatever it is, and iCloud Drive), each
    /// with what is purgeable in it; those with nothing purgeable are left out. Largest first.
    public static func scan(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                            progress: @escaping @Sendable (Double) -> Void = { _ in }) -> [Source] {
        let cloudStorage = home.appendingPathComponent("Library/CloudStorage")
        var roots = ((try? FileManager.default.contentsOfDirectory(atPath: cloudStorage.path)) ?? [])
            .filter { !$0.hasPrefix(".") }.map { (name: displayName($0), url: cloudStorage.appendingPathComponent($0)) }
        roots.append((name: "iCloud Drive", url: home.appendingPathComponent("Library/Mobile Documents")))
        let count = Double(roots.count)
        progress(0)
        return roots.enumerated().compactMap { index, root in
            defer { progress(Double(index + 1) / count) }
            return scan(root.url, name: root.name, progress: { fraction in
                progress((Double(index) + fraction) / count)
            })
        }.filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }
    }

    /// "OneDrive-Pessoal" -> "OneDrive (Pessoal)": File Provider names the folder after the service and the account.
    public static func displayName(_ folder: String) -> String {
        guard let dash = folder.firstIndex(of: "-") else { return folder }
        return "\(folder[..<dash]) (\(folder[folder.index(after: dash)...]))"
    }

    /// Uploaded local copies under one folder, by its top-level folders. nil when it cannot be read.
    static func scan(_ root: URL, name: String, progress: @escaping @Sendable (Double) -> Void = { _ in },
                     state: @escaping @Sendable (URL) -> CloudState = CloudState.read) -> Source? {
        let rootPath = root.path
        let started = Date()
        var found: [(path: String, bytes: UInt64)] = []
        progress(0)
        // Enumerating first gives metadata inspection a real denominator. File Provider resource reads dominate the scan; a
        // bounded number run together, and parent Keep Downloaded markers are read once per scan rather than once per file.
        let walked = walk(rootPath, timeLimit: timeLimit) { found.append(($0, $1)) }
        guard walked else { return nil }
        progress(0.05)
        let candidates = found
        let queue = JobCounter(count: candidates.count)
        let pinned = ScanPins(root: root)
        let totals = CloudScanTotals()
        DispatchQueue.concurrentPerform(iterations: min(4, max(candidates.count, 1))) { _ in
            while let index = queue.next(), Date().timeIntervalSince(started) <= timeLimit {
                let candidate = candidates[index]
                let url = URL(fileURLWithPath: candidate.path)
                let eligible = !pinned.isKept(url) && state(url).canEvict
                let relative = candidate.path.dropFirst(rootPath.count).drop { $0 == "/" }
                let top = relative.contains("/") ? String(relative.prefix { $0 != "/" }) : "(top level)"
                let done = totals.record(bytes: candidate.bytes, folder: top, eligible: eligible)
                progress(0.05 + 0.95 * Double(done) / Double(candidates.count))
            }
        }
        progress(1)
        return Source(name: name, path: rootPath, bytes: totals.bytes, files: totals.files,
                      folders: totals.folders.values.sorted { $0.bytes > $1.bytes })
    }

    /// Calls `visit` with each locally allocated file under `rootPath` and its allocated size, until `timeLimit` seconds have
    /// passed. False when the folder cannot be read.
    static func walk(_ rootPath: String, timeLimit: TimeInterval, _ visit: (String, UInt64) -> Void) -> Bool {
        guard FileManager.default.fileExists(atPath: rootPath), let rootCopy = strdup(rootPath) else { return false }
        defer { free(rootCopy) }
        var paths: [UnsafeMutablePointer<CChar>?] = [rootCopy, nil]
        guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil) else { return false }
        defer { fts_close(fts) }
        let started = Date()
        while let entry = fts_read(fts) {
            if Date().timeIntervalSince(started) > timeLimit { break }
            // A folder still only in the cloud (dataless) holds nothing on this Mac; listing it would make the provider fetch it.
            if Int32(entry.pointee.fts_info) == FTS_D, let stat = entry.pointee.fts_statp, stat.pointee.st_flags & UInt32(SF_DATALESS) != 0 {
                fts_set(fts, entry, FTS_SKIP)
                continue
            }
            guard Int32(entry.pointee.fts_info) == FTS_F, let cPath = entry.pointee.fts_path else { continue }
            let info = entry.pointee.fts_statp.pointee
            guard info.st_flags & UInt32(SF_DATALESS) == 0 else { continue }
            let allocated = UInt64(max(info.st_blocks, 0)) * 512
            guard allocated > 0 else { continue }
            visit(String(cString: cPath), allocated)
        }
        return true
    }

    /// Forgets the last scan, after downloads were removed.
    public static func forget() {
        lock.lock()
        cached = nil
        generation += 1
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

    struct CloudState: Sendable {
        var ubiquitous: Bool?
        var uploaded: Bool?
        var uploading: Bool?
        var conflicted: Bool?

        var canEvict: Bool { ubiquitous == true && uploaded == true && uploading == false && conflicted == false }

        static func read(_ url: URL) -> CloudState {
            let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemIsUploadedKey,
                                                          .ubiquitousItemIsUploadingKey, .ubiquitousItemHasUnresolvedConflictsKey])
            return CloudState(ubiquitous: values?.isUbiquitousItem, uploaded: values?.ubiquitousItemIsUploaded,
                              uploading: values?.ubiquitousItemIsUploading, conflicted: values?.ubiquitousItemHasUnresolvedConflicts)
        }
    }

    /// File Provider's Keep Downloaded marker can be inherited from a parent. Respect it for the whole cloud root as well.
    static func isKeptDownloaded(_ url: URL, root: URL) -> Bool {
        var path = url.standardizedFileURL.path
        let boundary = root.standardizedFileURL.path
        while path == boundary || path.hasPrefix(boundary + "/") {
            var value: UInt8 = 0
            let length = getxattr(path, "com.apple.fileprovider.pinned#PX", &value, 1, 0, XATTR_NOFOLLOW)
            if length > 0 && value != 0 && value != 48 { return true }
            if length < 0 && errno != ENOATTR && errno != ENOTSUP { return true }
            if path == boundary { break }
            path = (path as NSString).deletingLastPathComponent
        }
        return false
    }

    /// Removes the local copies of the files in a cloud folder that are already in the cloud, as Finder's Free Up Space does, with
    /// the API made for it (`FileManager.evictUbiquitousItem`), which iCloud Drive and every File Provider app (OneDrive, Google
    /// Drive, Dropbox) answer. Each file must be uploaded, not uploading, without conflicts and not marked Keep Downloaded. The
    /// provider makes the final eviction decision. The files stay in the cloud and download again when opened.
    /// The largest go first, so the space comes back early; `progress` gets the files done, their number, and the bytes removed.
    public static func removeDownloads(in root: URL, progress: @escaping @Sendable (Int, Int, UInt64) -> Void = { _, _, _ in }) -> Removal {
        guard isCloudFolder(root.path) else { return Removal() }
        var found: [(path: String, bytes: UInt64)] = []
        _ = walk(root.path, timeLimit: 120) { found.append(($0, $1)) }
        let candidates = found.sorted { $0.bytes > $1.bytes }
        let total = candidates.count
        let state = RemovalState()
        progress(0, total, 0)
        DispatchQueue.concurrentPerform(iterations: min(concurrentRemovals, max(total, 1))) { worker in
            for index in stride(from: worker, to: total, by: concurrentRemovals) {
                let candidate = candidates[index]
                let url = URL(fileURLWithPath: candidate.path)
                let outcome: Result<UInt64, Error>?
                if CloudState.read(url).canEvict, !isKeptDownloaded(url, root: root) {
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

/// Only the scan memoizes inherited markers. Eviction always checks the current markers again (`isKeptDownloaded`).
private final class ScanPins: @unchecked Sendable {
    private let lock = NSLock()
    private let root: String
    private var parents: [String: Bool] = [:]

    init(root: URL) { self.root = root.standardizedFileURL.path }

    func isKept(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        if Self.marker(path) { return true }
        return lock.withLock { inherited((path as NSString).deletingLastPathComponent) }
    }

    private func inherited(_ path: String) -> Bool {
        guard path == root || path.hasPrefix(root + "/") else { return false }
        if let cached = parents[path] { return cached }
        let kept = Self.marker(path) || (path != root && inherited((path as NSString).deletingLastPathComponent))
        parents[path] = kept
        return kept
    }

    private static func marker(_ path: String) -> Bool {
        var value: UInt8 = 0
        let length = getxattr(path, "com.apple.fileprovider.pinned#PX", &value, 1, 0, XATTR_NOFOLLOW)
        if length > 0 { return value != 0 && value != 48 }
        return length < 0 && errno != ENOATTR && errno != ENOTSUP
    }
}

private final class CloudScanTotals: @unchecked Sendable {
    private let lock = NSLock()
    private var done = 0
    private(set) var bytes: UInt64 = 0
    private(set) var files = 0
    private(set) var folders: [String: PurgeableDocuments.Folder] = [:]

    func record(bytes: UInt64, folder: String, eligible: Bool) -> Int {
        lock.withLock {
            done += 1
            if eligible {
                self.bytes += bytes
                files += 1
                folders[folder, default: .init(name: folder, bytes: 0, files: 0)].bytes += bytes
                folders[folder, default: .init(name: folder, bytes: 0, files: 0)].files += 1
            }
            return done
        }
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

    public struct Completion: Sendable, Equatable {
        public var revision: Int
        public var path: String
        public var source: PurgeableDocuments.Source?
        public var localSize: FileTreeSize?
        public init(revision: Int, path: String, source: PurgeableDocuments.Source?, localSize: FileTreeSize?) {
            self.revision = revision; self.path = path; self.source = source; self.localSize = localSize
        }
    }

    private let lock = NSLock()
    private var revision = 0
    private var completed: [String: Completion] = [:]
    private var running: [String: Progress] = [:]

    /// The removals running now, by cloud folder.
    public func current() -> [String: Progress] {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    /// Completed target measurements since a module's snapshot, shared by both cloud-file surfaces.
    public func changes(since previous: Int = 0) -> (revision: Int, completions: [Completion]) {
        lock.lock()
        defer { lock.unlock() }
        return (revision, completed.values.filter { $0.revision > previous }.sorted { $0.revision < $1.revision })
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
            let removal = PurgeableDocuments.removeDownloads(in: root) { done, total, bytes in
                // Workers report together; a count that arrives late must not move the flag back.
                self.lock.withLock {
                    if done >= self.running[path]?.done ?? 0 { self.running[path] = Progress(done: done, total: total, bytes: bytes) }
                }
            }
            var freed: UInt64 = 0
            if let before, let after = DataVolume.settledFreeBytes(), after > before { freed = after - before }
            // Keep the progress flag through verification. No whole-module scan or service query is needed.
            let source = PurgeableDocuments.refreshSource(root)
            let local = FileTreeSizer(countsPurgeable: true).size(at: root)
            self.lock.lock()
            self.revision += 1
            self.completed[path] = Completion(revision: self.revision, path: path, source: source, localSize: local)
            self.running[path] = nil
            self.lock.unlock()
            finished(removal, freed)
        }
        return true
    }
}
