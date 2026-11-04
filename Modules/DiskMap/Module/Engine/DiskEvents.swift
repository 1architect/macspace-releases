import Foundation
import CoreServices
import MacSpacePlatform

/// FSEvents replays changes since the persisted index watermark, including changes while MacSpace was closed.
final class DiskEvents: @unchecked Sendable {
    struct Changes: Sendable { var shallow = Set<String>(); var recursive = Set<String>() }
    static let maximumPendingScopes = 8_192
    static let historyGrace: TimeInterval = 1
    private final class Target: @unchecked Sendable { weak var owner: DiskEvents? }
    private var target = Target()
    private let lock = NSLock()
    private var pending = Changes()
    private var stream: FSEventStreamRef?
    private let history = DispatchSemaphore(value: 0)
    private var historyPending = false
    private var coveredThrough: UInt64 = 0
    private static let controlFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagEventIdsWrapped)
    private let root: String
    private let excluded: [String]
    private let queue = DispatchQueue(label: "com.macspace.disk-map.events", qos: .utility)

    init(root: String, since: UInt64, excluded: [String], startStream: Bool = true) {
        self.root = root; self.excluded = excluded
        historyPending = since != 0
        target.owner = self
        guard startStream else { return }
        start(since: since)
    }
    private func start(since: UInt64) {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(target).toOpaque(), retain: { raw in
            guard let raw else { return nil }
            _ = Unmanaged<Target>.fromOpaque(raw).retain()
            return raw
        }, release: { raw in
            if let raw { Unmanaged<Target>.fromOpaque(raw).release() }
        }, copyDescription: nil)
        stream = FSEventStreamCreate(nil, { _, info, count, raw, flags, ids in
            guard let info else { return }
            guard let watcher = Unmanaged<Target>.fromOpaque(info).takeUnretainedValue().owner else { return }
            let paths = unsafeBitCast(raw, to: NSArray.self)
            let coverage = watcher.coverage
            for i in 0..<count {
                if flags[i] & DiskEvents.controlFlags != 0 {
                    watcher.note("", flags: flags[i], eventID: ids[i])
                    continue
                }
                if coverage.root || ids[i] <= coverage.through { continue }
                if watcher.needsRootScan {
                    for n in i..<count where flags[n] & DiskEvents.controlFlags != 0 {
                        watcher.note("", flags: flags[n], eventID: ids[n])
                    }
                    break
                }
                if let path = paths[i] as? String { watcher.note(path, flags: flags[i], eventID: ids[i]) }
            }
        }, &context, [root] as CFArray, since == 0 ? FSEventStreamEventId(kFSEventStreamEventIdSinceNow) : since, 0.5,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot))
        if let stream { FSEventStreamSetDispatchQueue(stream, queue); FSEventStreamStart(stream) }
    }
    deinit { target.owner = nil; if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) } }
    private func restartCoveredHistory(at cursor: UInt64) {
        guard let oldStream = stream, isReplayingHistory else { return }
        // The full scan covers everything through cursor. Recreate the stream at that exact ID:
        // subsequent changes are replayed from the boundary even if they arrive during replacement.
        target.owner = nil
        FSEventStreamStop(oldStream); FSEventStreamInvalidate(oldStream); FSEventStreamRelease(oldStream)
        stream = nil
        target = Target(); target.owner = self
        while history.wait(timeout: .now()) == .success {}
        lock.withLock { historyPending = true }
        start(since: cursor)
    }
    private var coverage: (root: Bool, through: UInt64) { lock.withLock { (pending.recursive.contains(root), coveredThrough) } }
    var coveredEventID: UInt64 { lock.withLock { coveredThrough } }
    private var needsRootScan: Bool { lock.withLock { pending.recursive.contains(root) } }
    var isReplayingHistory: Bool { lock.withLock { historyPending } }
    var hasChanges: Bool { lock.withLock { !pending.shallow.isEmpty || !pending.recursive.isEmpty } }
    func drain() -> Changes { lock.withLock { let next = pending; pending = Changes(); return next } }
    func mark(_ paths: [String], recursive: Bool = false) {
        for path in paths {
            note(path, flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile))
            if recursive { note(path, flags: FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)) }
        }
    }
    func note(_ rawPath: String, flags: FSEventStreamEventFlags, eventID: UInt64? = nil) {
        let lost = FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagEventIdsWrapped)
        if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) != 0 {
            let notify = lock.withLock { let pending = historyPending; historyPending = false; return pending }
            if notify { history.signal() }
            if flags & lost == 0 { return }
        }
        // A queued root scan covers every detail until drain(). Processing millions of older file
        // events cannot add information, and previously made FlushSync block scan startup for minutes.
        if flags & lost != 0 {
            lock.withLock {
                if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped) != 0 { coveredThrough = 0 }
                pending = Changes(recursive: [root])
            }
            history.signal()
            return
        }
        if lock.withLock({ pending.recursive.contains(root) || eventID.map { $0 <= coveredThrough } == true }) { return }
        var path = rawPath
        if path.utf8.count > 1, path.hasSuffix("/") { path.removeLast() }
        guard FileReviewPolicy.isNormalizedAbsolutePath(path) else { return }
        // File events may use the POSIX /private spelling even when an older caller used /var or /tmp.
        if root.hasPrefix("/private/"), (path == "/var" || path.hasPrefix("/var/") || path == "/tmp" || path.hasPrefix("/tmp/")) { path = "/private" + path }
        if !root.hasPrefix("/private/"), (root.hasPrefix("/var/") || root.hasPrefix("/tmp/")), path.hasPrefix("/private/") { path = String(path.dropFirst(8)) }
        if root == "/", path == "/System/Volumes/Data" || path.hasPrefix("/System/Volumes/Data/") { path = String(path.dropFirst("/System/Volumes/Data".count)); if path.isEmpty { path = "/" } }
        guard root == "/" || path == root || path.hasPrefix(root + "/"), !excluded.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { return }
        lock.withLock {
            if pending.recursive.contains(root) { return }
            if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0 {
                if path == root { pending = Changes(recursive: [root]); history.signal(); return }
                pending.recursive.insert(path)
            }
            else if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0 { pending.shallow.insert(path) }
            let parent = (path as NSString).deletingLastPathComponent
            if root == "/" || parent == root || parent.hasPrefix(root + "/") { pending.shallow.insert(parent) }
            // A broad backlog is reconciled once, with bounded queue memory. No events are silently
            // dropped: a root rescan is the conservative fallback, as for a native dropped-events flag.
            if pending.shallow.count + pending.recursive.count > Self.maximumPendingScopes {
                pending = Changes(recursive: [root])
                history.signal()
            }
        }
    }
    private func coverPendingRoot() -> Bool {
        let boundary = lock.withLock { () -> UInt64? in
            guard pending.recursive.contains(root) else { return nil }
            // The upcoming full-root read starts after this watermark. It covers earlier changes
            // without decoding/replaying them; events beyond the boundary remain queued normally.
            coveredThrough = max(coveredThrough, FSEventsGetCurrentEventId())
            return coveredThrough
        }
        guard let boundary else { return false }
        restartCoveredHistory(at: boundary)
        return true
    }
    @discardableResult
    func flush() -> UInt64 {
        if coverPendingRoot() { return coveredEventID }
        if lock.withLock({ historyPending }) {
            _ = history.wait(timeout: .now() + Self.historyGrace)
            // FSEvents may take minutes to replay an old global checkpoint. A current full-root
            // read is bounded useful work; retain all coverage rather than block indefinitely.
            lock.withLock {
                if historyPending { pending = Changes(recursive: [root]) }
            }
        }
        if coverPendingRoot() { return coveredEventID }
        // FlushSync guarantees delivery of events that existed at invocation. The global ID sampled
        // before that call is a conservative, durable boundary; a later sampled ID could skip a new event.
        let through = FSEventsGetCurrentEventId()
        if let stream { FSEventStreamFlushSync(stream) }
        return through
    }
}
