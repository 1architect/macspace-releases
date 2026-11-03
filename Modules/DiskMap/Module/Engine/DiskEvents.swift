import Foundation
import CoreServices

/// FSEvents replays changes since the persisted index watermark, including changes while MacSpace was closed.
final class DiskEvents: @unchecked Sendable {
    struct Changes: Sendable { var shallow = Set<String>(); var recursive = Set<String>() }
    private let lock = NSLock()
    private var pending = Changes()
    private var stream: FSEventStreamRef?
    private let history = DispatchSemaphore(value: 0)
    private var historyPending = false
    private let root: String
    private let excluded: [String]
    private let queue = DispatchQueue(label: "com.macspace.disk-map.events", qos: .utility)

    init(root: String, since: UInt64, excluded: [String]) {
        self.root = root; self.excluded = excluded
        historyPending = since != 0
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        stream = FSEventStreamCreate(nil, { _, info, count, raw, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<DiskEvents>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(raw, to: NSArray.self) as! [String]
            for i in 0..<count { watcher.note(paths[i], flags: flags[i]) }
        }, &context, [root] as CFArray, since == 0 ? FSEventStreamEventId(kFSEventStreamEventIdSinceNow) : since, 0.5,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot))
        if let stream { FSEventStreamSetDispatchQueue(stream, queue); FSEventStreamStart(stream) }
    }
    deinit { if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) } }
    var hasChanges: Bool { lock.withLock { !pending.shallow.isEmpty || !pending.recursive.isEmpty } }
    func drain() -> Changes { lock.withLock { let next = pending; pending = Changes(); return next } }
    func mark(_ paths: [String], recursive: Bool = false) {
        for path in paths {
            note(path, flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile))
            if recursive { note(path, flags: FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)) }
        }
    }
    func note(_ rawPath: String, flags: FSEventStreamEventFlags) {
        if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) != 0 {
            let notify = lock.withLock { let pending = historyPending; historyPending = false; return pending }
            if notify { history.signal() }
            return
        }
        var path = rawPath
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        guard path.hasPrefix("/"), !path.utf8.contains(0), !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { return }
        // File events may use the POSIX /private spelling even when an older caller used /var or /tmp.
        if root.hasPrefix("/private/"), (path == "/var" || path.hasPrefix("/var/") || path == "/tmp" || path.hasPrefix("/tmp/")) { path = "/private" + path }
        if !root.hasPrefix("/private/"), (root.hasPrefix("/var/") || root.hasPrefix("/tmp/")), path.hasPrefix("/private/") { path = String(path.dropFirst(8)) }
        if root == "/", path == "/System/Volumes/Data" || path.hasPrefix("/System/Volumes/Data/") { path = String(path.dropFirst("/System/Volumes/Data".count)); if path.isEmpty { path = "/" } }
        guard root == "/" || path == root || path.hasPrefix(root + "/"), !excluded.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { return }
        lock.withLock {
            let lost = FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagEventIdsWrapped)
            if flags & lost != 0 { pending = Changes(recursive: [root]); return }
            if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0 { pending.recursive.insert(path) }
            else if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0 { pending.shallow.insert(path) }
            let parent = (path as NSString).deletingLastPathComponent
            if root == "/" || parent == root || parent.hasPrefix(root + "/") { pending.shallow.insert(parent) }
        }
    }
    func flush() {
        if lock.withLock({ historyPending }) { _ = history.wait(timeout: .now() + 3) }
        if let stream { FSEventStreamFlushSync(stream) }
    }
}
