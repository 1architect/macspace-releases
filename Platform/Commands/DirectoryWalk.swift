import Darwin
import Foundation

/// Walks a folder tree with `getattrlistbulk`: one system call returns a batch of a folder's entries with every attribute the
/// sizers need (type, device, flags, link count, sizes, and on request the clone family, private size and extended flags). The
/// `FileManager` enumerator it replaces made several calls per file, and an `NSURL` for each: System Data's scan spent 14 of its
/// 26 seconds there (26B5101f, 2026-10-13).
///
/// Given a `ScanPool`, idle workers of the pool take folders of the tree as they are found: one large tree (a cloud folder of 6
/// seconds) no longer finishes alone after every other one.
enum DirectoryWalk {
    struct Entry {
        let type: UInt32
        let device: Int32
        /// `st_flags` (`SF_DATALESS` for a folder still in the cloud).
        let flags: UInt32
        let linkCount: UInt32
        let logicalBytes: UInt64
        let allocatedBytes: UInt64
        /// Only when the walk asks for them (`extended`): 0 otherwise.
        let cloneFamily: UInt64
        let privateBytes: UInt64
        let extendedFlags: UInt64

        var isDirectory: Bool { type == UInt32(VDIR.rawValue) }
        var isRegularFile: Bool { type == UInt32(VREG.rawValue) }
        var isDataless: Bool { flags & UInt32(SF_DATALESS) != 0 }
    }

    /// What `visit` decides for a folder.
    enum Step { case descend, skip }

    /// Walks the folder at `root` (not followed if it is a link) and calls `visit` with each entry's path (built only when asked for)
    /// and attributes. Folders on another volume than the root's are passed to `visit` but never entered. With a pool, `visit` runs on
    /// several threads at once, each with a `State` of its own (`makeState`); every state is returned, for the caller to add up.
    /// `unreadable` counts the folders that could not be listed (no permission, SIP), whose contents are left out.
    static func walk<State>(_ root: String, extended: Bool, pool: ScanPool? = nil, refusesLinks: Bool = false, makeState: @escaping () -> State,
                            visit: @escaping (inout State, _ path: () -> String, Entry) -> Step) -> (states: [State], unreadable: Int) {
        var rootInfo = stat()
        // A folder still only in the cloud is not listed: listing it would make the cloud app fetch it.
        guard lstat(root, &rootInfo) == 0, rootInfo.st_mode & S_IFMT == S_IFDIR, rootInfo.st_flags & UInt32(SF_DATALESS) == 0 else { return ([], 0) }
        let walk = Walk(root: root, device: rootInfo.st_dev, extended: extended, pool: pool, refusesLinks: refusesLinks, makeState: makeState, visit: visit)
        walk.work(helper: false)
        walk.helpers.wait()
        return walk.result()
    }

    /// Sequential walk with one state.
    static func walk<State>(_ root: String, extended: Bool, initial: State,
                            visit: @escaping (inout State, _ path: () -> String, Entry) -> Step) -> (state: State, unreadable: Int) {
        let result = walk(root, extended: extended, pool: nil, makeState: { initial }, visit: visit)
        return (result.states.first ?? initial, result.unreadable)
    }

    /// One walk's shared queue of folders still to list. Workers take the last one found (depth first), list it, and put back the
    /// folders it holds; the walk is over when the queue is empty and no worker is listing.
    private final class Walk<State>: @unchecked Sendable {
        let root: String
        let device: Int32
        let pool: ScanPool?
        let makeState: () -> State
        let visit: (inout State, () -> String, Entry) -> Step
        let helpers = DispatchGroup()
        private var states: [State] = []
        private var unreadable = 0

        private let condition = NSCondition()
        private var folders: [String]
        private var listing = 0
        private var list = attrlist()
        private let options: UInt64
        private let openFlags: Int32

        init(root: String, device: Int32, extended: Bool, pool: ScanPool?, refusesLinks: Bool, makeState: @escaping () -> State,
             visit: @escaping (inout State, () -> String, Entry) -> Step) {
            openFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | (refusesLinks ? O_NOFOLLOW_ANY : 0)
            self.root = root
            self.device = device
            self.pool = pool
            self.makeState = makeState
            self.visit = visit
            folders = [root]
            list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
            list.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_ERROR | ATTR_CMN_NAME | ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE | ATTR_CMN_FLAGS)
            list.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT | ATTR_FILE_TOTALSIZE | ATTR_FILE_ALLOCSIZE)
            if extended { list.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE | ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_EXT_FLAGS) }
            options = UInt64(extended ? FSOPT_ATTR_CMN_EXTENDED : 0)
        }

        func result() -> (states: [State], unreadable: Int) {
            condition.lock()
            defer { condition.unlock() }
            return (states, unreadable)
        }

        /// A helper leaves as soon as nothing is waiting, giving its place in the pool back; the walk's own thread waits for the
        /// folders still being listed, which may hold more.
        private func next(helper: Bool) -> String? {
            condition.lock()
            defer { condition.unlock() }
            while folders.isEmpty && listing > 0 && !helper { condition.wait() }
            guard let folder = folders.popLast() else { condition.broadcast(); return nil }
            listing += 1
            return folder
        }

        private func listed(_ found: [String], failed: Bool) {
            condition.lock()
            folders.append(contentsOf: found)
            listing -= 1
            if failed { unreadable += 1 }
            let waiting = folders.count
            condition.broadcast()
            condition.unlock()
            if waiting > 1, let pool, pool.tryAcquire() {
                helpers.enter()
                DispatchQueue.global(qos: .utility).async { [self] in
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
                var found: [String] = []
                let complete = Self.list(folder, &request, flags: openFlags, options: options, buffer: buffer, capacity: capacity, rootDevice: device) { name, entry in
                    var built: String?
                    let path = { () -> String in
                        if let built { return built }
                        let made = folder.hasSuffix("/") ? folder + String(cString: name) : folder + "/" + String(cString: name)
                        built = made
                        return made
                    }
                    if visit(&state, path, entry) == .descend, entry.isDirectory, entry.device == device { found.append(path()) }
                }
                listed(found, failed: !complete)
            }
            condition.lock()
            states.append(state)
            condition.unlock()
        }

        /// Lists one folder; false when it could not be listed, or only in part.
        static func list(_ folder: String, _ request: inout attrlist, flags: Int32, options: UInt64, buffer: UnsafeMutableRawPointer, capacity: Int, rootDevice: Int32,
                         body: (UnsafePointer<CChar>, Entry) -> Void) -> Bool {
            let descriptor = open(folder, flags)
            guard descriptor >= 0 else { return false }
            defer { close(descriptor) }
            while true {
                let count = getattrlistbulk(descriptor, &request, buffer, capacity, options)
                if count < 0 { return false }
                if count == 0 { return true }
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
                        if error != 0 { continue }
                    }
                    guard returned.commonattr & attrgroup_t(ATTR_CMN_NAME) != 0 else { continue }
                    let reference = field.loadUnaligned(as: attrreference_t.self)
                    let name = UnsafePointer((field + Int(reference.attr_dataoffset)).assumingMemoryBound(to: CChar.self))
                    field += MemoryLayout<attrreference_t>.size
                    var device = rootDevice
                    if returned.commonattr & attrgroup_t(ATTR_CMN_DEVID) != 0 { device = field.loadUnaligned(as: Int32.self); field += 4 }
                    var type: UInt32 = 0
                    if returned.commonattr & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 { type = field.loadUnaligned(as: UInt32.self); field += 4 }
                    var flags: UInt32 = 0
                    if returned.commonattr & attrgroup_t(ATTR_CMN_FLAGS) != 0 { flags = field.loadUnaligned(as: UInt32.self); field += 4 }
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
                    body(name, Entry(type: type, device: device, flags: flags, linkCount: links, logicalBytes: logical, allocatedBytes: allocated,
                                     cloneFamily: family, privateBytes: privateBytes, extendedFlags: extendedFlags))
                }
            }
        }
    }
}

/// Threads a scan may add to the walks it runs: a walk takes one when it has folders waiting and gives it back when it has none.
/// A scan that runs its own workers gives each worker's place to the pool once that worker has no tree left to start.
public final class ScanPool: @unchecked Sendable {
    private let lock = NSLock()
    private var free: Int

    public init(free: Int) { self.free = max(free, 0) }

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
