import Darwin
import Foundation

/// Walks a folder tree with `getattrlistbulk`: one system call returns a batch of a folder's entries with every attribute the
/// sizers need (type, device, flags, link count, sizes, and on request the clone family, private size and extended flags). The
/// `FileManager` enumerator it replaces made several calls per file, and an `NSURL` for each: System Data's scan spent 14 of its
/// 26 seconds there (26B5101f, 2026-10-13).
///
/// Given a `ScanPool`, idle workers of the pool take folders of the tree as they are found: one large tree (a cloud folder of 6
/// seconds) no longer finishes alone after every other one.
public enum DirectoryWalk {
    public struct Entry {
        public let type: UInt32
        public let device: Int32
        /// `st_flags` (`SF_DATALESS` for a folder still in the cloud).
        public let flags: UInt32
        public let ownerUID: UInt32
        /// Whether the batch returned the owner and flags needed to reuse directory metadata.
        public let hasDirectoryMetadata: Bool
        public let linkCount: UInt32
        public let logicalBytes: UInt64
        public let allocatedBytes: UInt64
        public let modifiedAt: Date?
        /// Only when the walk asks for them (`extended`): 0 otherwise.
        public let cloneFamily: UInt64
        public let privateBytes: UInt64
        public let extendedFlags: UInt64
        /// Exact leaf-name suffix for application exclusion, without constructing a full path.
        public let hasApplicationSuffix: Bool

        public var isDirectory: Bool { type == UInt32(VDIR.rawValue) }
        public var isRegularFile: Bool { type == UInt32(VREG.rawValue) }
        public var isDataless: Bool { flags & UInt32(SF_DATALESS) != 0 }
    }

    @dynamicMemberLookup
    struct Facts {
        let entry: Entry
        let fileID: UInt64
        let fromArchive: Bool
        subscript<Value>(dynamicMember path: KeyPath<Entry, Value>) -> Value { entry[keyPath: path] }
    }

    /// Streams one directory in a fixed-size native buffer. No NSURL array or per-file stat call is created.
    /// The callback finishes before this returns; nested scans should start after it returns to release the buffer first.
    @discardableResult
    public static func entries(at path: String, includingModificationDate: Bool = false, visit: (String, Entry) -> Void) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_flags & UInt32(SF_DATALESS) == 0 else { return false }
        let capacity = 256 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 8)
        defer { buffer.deallocate() }
        var request = attributes(extended: false)
        if includingModificationDate { request.commonattr |= attrgroup_t(ATTR_CMN_MODTIME) }
        return Walk<Void>.list(path, &request, flags: O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW,
                               options: 0, buffer: buffer, capacity: capacity, rootDevice: info.st_dev) { name, entry in
            visit(String(cString: name), entry.entry)
        }
    }

    private static func attributes(extended: Bool, fileIDs: Bool = false) -> attrlist {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_ERROR | ATTR_CMN_NAME | ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE | ATTR_CMN_OWNERID | ATTR_CMN_FLAGS)
        if fileIDs { list.commonattr |= attrgroup_t(ATTR_CMN_FILEID) }
        list.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT | ATTR_FILE_TOTALSIZE | ATTR_FILE_ALLOCSIZE)
        if extended { list.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE | ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_EXT_FLAGS) }
        return list
    }

    /// Bounded native workers share the existing directory queue. Each worker owns only its current
    /// buffer and accumulator; consumers synchronize shared writes, never retain an entire file tree.
    /// `directoryStarted` receives the enumerated owner before each directory, including empty/unreadable ones.
    /// A nil owner means the filesystem omitted those attributes; callers can fall back to a fresh metadata read.
    public static func scan<State>(_ root: String, devices: Set<Int32>, pool: ScanPool,
                                   makeState: @escaping () -> State,
                                   directoryStarted: ((inout State, UInt32?) -> Void)? = nil,
                                   visit: @escaping (inout State, () -> String, Entry) -> Bool,
                                   finished: @escaping (inout State, String, Bool) -> Void) {
        _ = walk(root, extended: false, pool: pool, devices: devices, modificationDates: true,
                 finished: finished, directoryStarted: directoryStarted, makeState: makeState,
                 visit: { state, path, entry in visit(&state, path, entry.entry) ? .descend : .skip })
    }

    /// What `visit` decides for a folder.
    enum Step { case descend, skip }

    /// Walks the folder at `root` (not followed if it is a link) and calls `visit` with each entry's path (built only when asked for)
    /// and attributes. Folders on another volume than the root's are passed to `visit` but never entered. With a pool, `visit` runs on
    /// several threads at once, each with a `State` of its own (`makeState`); every state is returned, for the caller to add up.
    /// `unreadable` counts the folders that could not be listed (no permission, SIP), whose contents are left out.
    static func walk<State>(_ root: String, extended: Bool, pool: ScanPool? = nil, refusesLinks: Bool = false,
                            devices: Set<Int32>? = nil, modificationDates: Bool = false, archive: DirectoryListingArchive? = nil,
                            finished: ((inout State, String, Bool) -> Void)? = nil,
                            directoryStarted: ((inout State, UInt32?) -> Void)? = nil, makeState: @escaping () -> State,
                            visit: @escaping (inout State, _ path: () -> String, Facts) -> Step) -> (states: [State], unreadable: Int) {
        var rootInfo = stat()
        // A folder still only in the cloud is not listed: listing it would make the cloud app fetch it.
        guard lstat(root, &rootInfo) == 0, rootInfo.st_mode & S_IFMT == S_IFDIR, rootInfo.st_flags & UInt32(SF_DATALESS) == 0 else { return ([], 0) }
        let walk = Walk(root: root, ownerUID: rootInfo.st_uid, device: rootInfo.st_dev, extended: extended, pool: pool, refusesLinks: refusesLinks, devices: devices, modificationDates: modificationDates, archive: archive, finished: finished, directoryStarted: directoryStarted, makeState: makeState, visit: visit)
        walk.work(helper: false)
        walk.helpers.wait()
        return walk.result()
    }

    /// Sequential walk with one state.
    static func walk<State>(_ root: String, extended: Bool, initial: State,
                            visit: @escaping (inout State, _ path: () -> String, Facts) -> Step) -> (state: State, unreadable: Int) {
        let result = walk(root, extended: extended, pool: nil, makeState: { initial }, visit: visit)
        return (result.states.first ?? initial, result.unreadable)
    }

    /// One walk's shared queue of folders still to list. Workers take the last one found (depth first), list it, and put back the
    /// folders it holds; the walk is over when the queue is empty and no worker is listing.
    private final class Walk<State>: @unchecked Sendable {
        let root: String
        let device: Int32
        let devices: Set<Int32>
        let finished: ((inout State, String, Bool) -> Void)?
        let directoryStarted: ((inout State, UInt32?) -> Void)?
        let archive: DirectoryListingArchive?
        let pool: ScanPool?
        let makeState: () -> State
        let visit: (inout State, () -> String, Facts) -> Step
        let helpers = DispatchGroup()
        private var states: [State] = []
        private var unreadable = 0

        private let condition = NSCondition()
        private struct Folder { let path: String; let ownerUID: UInt32?; var cached = false }
        private var folders: [Folder]
        private var listing = 0
        private var list = attrlist()
        private let options: UInt64
        private let openFlags: Int32
        private let qos: DispatchQoS.QoSClass

        init(root: String, ownerUID: UInt32, device: Int32, extended: Bool, pool: ScanPool?, refusesLinks: Bool, devices: Set<Int32>?, modificationDates: Bool, archive: DirectoryListingArchive?,
             finished: ((inout State, String, Bool) -> Void)?, directoryStarted: ((inout State, UInt32?) -> Void)?, makeState: @escaping () -> State,
             visit: @escaping (inout State, () -> String, Facts) -> Step) {
            // One of the two: `open` refuses `O_NOFOLLOW` together with `O_NOFOLLOW_ANY` (EINVAL on 26B5101f), which made every folder
            // unreadable to the helper and every place it measures 0 bytes (the version history, the Spotlight index and the system
            // log vanished from the page). `O_NOFOLLOW_ANY` refuses a link in the last part of the path too.
            openFlags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | (refusesLinks ? O_NOFOLLOW_ANY : O_NOFOLLOW)
            self.root = root
            self.device = device
            self.devices = devices ?? [device]
            self.finished = finished
            self.directoryStarted = directoryStarted
            self.archive = refusesLinks ? nil : archive
            self.pool = pool
            self.makeState = makeState
            self.visit = visit
            qos = pool?.qos ?? LoadWorkPriority.current
            folders = [Folder(path: root, ownerUID: ownerUID)]
            list = DirectoryWalk.attributes(extended: extended, fileIDs: self.archive != nil)
            if modificationDates { list.commonattr |= attrgroup_t(ATTR_CMN_MODTIME) }
            options = UInt64(extended ? FSOPT_ATTR_CMN_EXTENDED : 0)
        }

        func result() -> (states: [State], unreadable: Int) {
            condition.lock()
            defer { condition.unlock() }
            return (states, unreadable)
        }

        /// A helper leaves as soon as nothing is waiting, giving its place in the pool back; the walk's own thread waits for the
        /// folders still being listed, which may hold more.
        private func next(helper: Bool) -> Folder? {
            condition.lock()
            defer { condition.unlock() }
            while folders.isEmpty && listing > 0 && !helper { condition.wait() }
            guard let folder = folders.popLast() else { condition.broadcast(); return nil }
            listing += 1
            return folder
        }

        private func listed(_ found: [Folder], failed: Bool) {
            condition.lock()
            folders.append(contentsOf: found)
            listing -= 1
            if failed { unreadable += 1 }
            let waiting = folders.count
            condition.broadcast()
            condition.unlock()
            if waiting > 1, let pool, pool.tryAcquire() {
                helpers.enter()
                DispatchQueue.global(qos: qos).async { [self] in
                    work(helper: true)
                    pool.release()
                    helpers.leave()
                }
            }
        }

        func work(helper: Bool) {
            var state = makeState()
            let capacity = 256 * 1024
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 8)
            defer { buffer.deallocate() }
            var request = list
            while let folder = next(helper: helper) {
                var found: [Folder] = []
                if folder.cached {
                    var current = stat()
                    if lstat(folder.path, &current) != 0 {
                        finished?(&state, folder.path, false); listed([], failed: true); continue
                    }
                    // A cached parent's flags cannot authorize opening a now-dataless directory or a new mount/link.
                    if current.st_mode & S_IFMT != S_IFDIR || current.st_flags & UInt32(SF_DATALESS) != 0 || !devices.contains(current.st_dev) {
                        finished?(&state, folder.path, true); listed([], failed: false); continue
                    }
                }
                directoryStarted?(&state, folder.ownerUID)
                let complete = Self.list(folder.path, &request, flags: openFlags, options: options, buffer: buffer, capacity: capacity, rootDevice: device, archive: archive) { name, entry in
                    var built: String?
                    let path = { () -> String in
                        if let built { return built }
                        let made = folder.path.hasSuffix("/") ? folder.path + String(cString: name) : folder.path + "/" + String(cString: name)
                        built = made
                        return made
                    }
                    if visit(&state, path, entry) == .descend, entry.isDirectory, devices.contains(entry.device) { found.append(Folder(path: path(), ownerUID: entry.hasDirectoryMetadata ? entry.ownerUID : nil, cached: entry.fromArchive)) }
                }
                finished?(&state, folder.path, complete)
                listed(found, failed: !complete)
            }
            condition.lock()
            states.append(state)
            condition.unlock()
        }

        /// Lists one folder; false when it could not be listed, or only in part.
        static func list(_ folder: String, _ request: inout attrlist, flags: Int32, options: UInt64, buffer: UnsafeMutableRawPointer, capacity: Int, rootDevice: Int32,
                         archive: DirectoryListingArchive? = nil, body: (UnsafePointer<CChar>, Facts) -> Void) -> Bool {
            let descriptor = open(folder, flags)
            guard descriptor >= 0 else { return false }
            defer { close(descriptor) }
            let archive = archive.flatMap { $0.accepts(folder) ? $0 : nil }
            var before = stat()
            let identity: DirectoryListingArchive.Identity?
            if let archive, fstat(descriptor, &before) == 0 {
                let value = DirectoryListingArchive.Identity(before)
                identity = archive.accepts(value) ? value : nil
            } else { identity = nil }
            let key = "\(request.commonattr):\(request.fileattr):\(request.forkattr):\(options):\(rootDevice)"
            if let archive, let identity, let data = archive.read(folder, request: key, identity: identity),
               let batches = DirectoryAttributeBatches.decode(data, request: request) {
                for batch in batches {
                    batch.bytes.withUnsafeBytes { raw in
                        _ = parse(UnsafeMutableRawPointer(mutating: raw.baseAddress!), count: batch.count, rootDevice: rootDevice, cached: true, body: body)
                    }
                }
                return true
            }
            var complete = true
            var saved: [DirectoryAttributeBatches.Batch]? = identity == nil ? nil : []
            var savedBytes = 8
            while true {
                let count = getattrlistbulk(descriptor, &request, buffer, capacity, options)
                if count < 0 { return false }
                if count == 0 { break }
                let parsed = parse(buffer, count: count, rootDevice: rootDevice, cached: false, body: body)
                complete = complete && parsed.complete
                if saved != nil {
                    savedBytes += 8 + parsed.used
                    if parsed.used > 0 && parsed.used <= capacity && savedBytes <= DirectoryListingArchive.maximumPayload {
                        saved!.append(.init(count: count, bytes: Data(bytes: buffer, count: parsed.used)))
                    } else { saved = nil }
                }
            }
            if complete, let archive, let identity, let saved, let payload = DirectoryAttributeBatches.encode(saved, request: request),
               fstat(descriptor, &before) == 0, identity == DirectoryListingArchive.Identity(before) {
                archive.record(payload, path: folder, request: key, identity: identity)
            }
            return complete
        }
        private static func parse(_ buffer: UnsafeMutableRawPointer, count: Int32, rootDevice: Int32, cached: Bool,
                                  body: (UnsafePointer<CChar>, Facts) -> Void) -> (complete: Bool, used: Int) {
            var complete = true
            var cursor = buffer
            for _ in 0..<count {
                let length = Int(cursor.loadUnaligned(as: UInt32.self))
                defer { cursor += length }
                var field = cursor + 4
                let returned = field.loadUnaligned(as: attribute_set_t.self)
                field += MemoryLayout<attribute_set_t>.size
                // In the order getattrlistbulk packs them: the error first, then each group in bit order.
                if returned.commonattr & attrgroup_t(ATTR_CMN_ERROR) != 0 {
                    let error = field.loadUnaligned(as: UInt32.self)
                    field += 4
                    if error != 0 { complete = false; continue }
                }
                guard returned.commonattr & attrgroup_t(ATTR_CMN_NAME) != 0 else { complete = false; continue }
                let reference = field.loadUnaligned(as: attrreference_t.self)
                let name = UnsafePointer((field + Int(reference.attr_dataoffset)).assumingMemoryBound(to: CChar.self))
                let nameLength = strlen(name)
                let appSuffix = nameLength >= 4 && name[nameLength - 4] == 46 && name[nameLength - 3] == 97
                    && name[nameLength - 2] == 112 && name[nameLength - 1] == 112
                field += MemoryLayout<attrreference_t>.size
                var device = rootDevice
                if returned.commonattr & attrgroup_t(ATTR_CMN_DEVID) != 0 { device = field.loadUnaligned(as: Int32.self); field += 4 }
                var type: UInt32 = 0
                if returned.commonattr & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 { type = field.loadUnaligned(as: UInt32.self); field += 4 }
                var modifiedAt: Date?
                if returned.commonattr & attrgroup_t(ATTR_CMN_MODTIME) != 0 {
                    let time = field.loadUnaligned(as: timespec.self); field += MemoryLayout<timespec>.size
                    if time.tv_sec > 0 { modifiedAt = Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_nsec) / 1e9) }
                }
                var ownerUID: UInt32 = 0
                if returned.commonattr & attrgroup_t(ATTR_CMN_OWNERID) != 0 { ownerUID = field.loadUnaligned(as: UInt32.self); field += 4 }
                var flags: UInt32 = 0
                if returned.commonattr & attrgroup_t(ATTR_CMN_FLAGS) != 0 { flags = field.loadUnaligned(as: UInt32.self); field += 4 }
                var fileID: UInt64 = 0
                if returned.commonattr & attrgroup_t(ATTR_CMN_FILEID) != 0 { fileID = field.loadUnaligned(as: UInt64.self); field += 8 }
                var links: UInt32 = 1
                var logical: UInt64 = 0
                var allocated: UInt64 = 0
                if returned.fileattr & attrgroup_t(ATTR_FILE_LINKCOUNT) != 0 { links = field.loadUnaligned(as: UInt32.self); field += 4 }
                if returned.fileattr & attrgroup_t(ATTR_FILE_TOTALSIZE) != 0 { logical = UInt64(max(field.loadUnaligned(as: Int64.self), 0)); field += 8 }
                if returned.fileattr & attrgroup_t(ATTR_FILE_ALLOCSIZE) != 0 { allocated = UInt64(max(field.loadUnaligned(as: Int64.self), 0)); field += 8 }
                var privateBytes: UInt64 = 0
                var family: UInt64 = 0
                var extendedFlags: UInt64 = 0
                if returned.forkattr & attrgroup_t(ATTR_CMNEXT_PRIVATESIZE) != 0 { privateBytes = UInt64(max(field.loadUnaligned(as: Int64.self), 0)); field += 8 }
                if returned.forkattr & attrgroup_t(ATTR_CMNEXT_CLONEID) != 0 { family = field.loadUnaligned(as: UInt64.self); field += 8 }
                if returned.forkattr & attrgroup_t(ATTR_CMNEXT_EXT_FLAGS) != 0 { extendedFlags = field.loadUnaligned(as: UInt64.self); field += 8 }
                body(name, Facts(entry: Entry(type: type, device: device, flags: flags, ownerUID: ownerUID,
                                 hasDirectoryMetadata: returned.commonattr & attrgroup_t(ATTR_CMN_OWNERID | ATTR_CMN_FLAGS) == attrgroup_t(ATTR_CMN_OWNERID | ATTR_CMN_FLAGS), linkCount: links, logicalBytes: logical, allocatedBytes: allocated, modifiedAt: modifiedAt,
                                 cloneFamily: family, privateBytes: privateBytes, extendedFlags: extendedFlags, hasApplicationSuffix: appSuffix), fileID: fileID, fromArchive: cached))
            }
            return (complete, buffer.distance(to: cursor))
        }
    }
}

/// Threads a scan may add to the walks it runs: a walk takes one when it has folders waiting and gives it back when it has none.
/// A scan that runs its own workers gives each worker's place to the pool once that worker has no tree left to start.
public final class ScanPool: @unchecked Sendable {
    private let lock = NSLock()
    private var free: Int
    let qos: DispatchQoS.QoSClass
    let archive: DirectoryListingArchive?

    public convenience init(free: Int) { self.init(free: free, archive: nil) }
    public init(free: Int, archive: DirectoryListingArchive?) {
        self.free = max(free, 0); qos = LoadWorkPriority.current; self.archive = archive
    }

    func tryAcquire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard free > 0 else { return false }
        free -= 1
        return true
    }

    public func release() {
        lock.lock()
        free += 1
        lock.unlock()
    }
}
