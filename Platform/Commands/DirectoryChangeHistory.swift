import CoreServices
import Foundation

/// A snapshot validates persisted facts against the complete event history before reading them. Lost/unavailable history is
/// a cache miss, never permission to reuse an old directory. Events after that boundary are retired before saving the next one.
final class DirectoryChangeHistory: @unchecked Sendable {
    struct Changes: Sendable {
        var lost = false
        var shallow = Set<String>()
        var recursive = Set<String>()
    }
    private final class Target: @unchecked Sendable { weak var owner: DirectoryChangeHistory? }
    private var target = Target()
    private let lock = NSLock()
    private let history = DispatchSemaphore(value: 0)
    private let fence = DispatchSemaphore(value: 0)
    private var wantedFence: String?
    private let directory: URL
    private let queue = DispatchQueue(label: "com.macspace.directory-facts.events", qos: .utility)
    private var stream: FSEventStreamRef?
    private var running = false
    private var processedThrough: UInt64 = 0
    private var pending = Changes()
    private var replaying: Bool
    private let excluded: String

    static func canonical(_ path: String) -> String {
        var value = path
        if value == "/var" || value.hasPrefix("/var/") || value == "/tmp" || value.hasPrefix("/tmp/") { value = "/private" + value }
        if value == DataVolume.path || value.hasPrefix(DataVolume.path + "/") {
            value = String(value.dropFirst(DataVolume.path.count)); if value.isEmpty { value = "/" }
        }
        if value.count > 1 && value.hasSuffix("/") { value.removeLast() }
        return value
    }

    init(since: UInt64, excluding: String) {
        excluded = Self.canonical(excluding); directory = URL(fileURLWithPath: excluding); replaying = since != 0
        start(since: since)
    }
    private func start(since: UInt64) {
        processedThrough = since
        target.owner = self
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(target).toOpaque(), retain: { raw in
            guard let raw else { return nil }; _ = Unmanaged<Target>.fromOpaque(raw).retain(); return raw
        }, release: { raw in if let raw { Unmanaged<Target>.fromOpaque(raw).release() } }, copyDescription: nil)
        stream = FSEventStreamCreate(nil, { _, info, count, raw, flags, ids in
            guard let info else { return }
            let target = Unmanaged<Target>.fromOpaque(info).takeUnretainedValue()
            guard let owner = target.owner else { return }
            let paths = unsafeBitCast(raw, to: NSArray.self)
            var through: UInt64 = 0
            for index in 0..<count {
                guard target.owner != nil else { return }
                owner.note(paths[index] as? String ?? "", flags: flags[index])
                through = max(through, ids[index])
            }
            owner.lock.withLock { owner.processedThrough = max(owner.processedThrough, through) }
        }, &context, ["/", DataVolume.path] as CFArray, since == 0 ? FSEventStreamEventId(kFSEventStreamEventIdSinceNow) : since, 0.1,
        FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            running = FSEventStreamStart(stream)
            if !running { pending.lost = true }
        } else { pending.lost = true }
    }
    deinit { stop() }
    func stop() {
        target.owner = nil
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
        stream = nil; running = false
    }

    func note(_ raw: String, flags: FSEventStreamEventFlags) {
        let lost = FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
            | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount)
        let done = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) != 0
        lock.withLock {
            if done { replaying = false; history.signal() }
            if flags & lost != 0 { pending = Changes(lost: true); history.signal(); return }
            if done { return }
            guard !raw.isEmpty else { return }
            let path = Self.canonical(raw)
            if path == wantedFence { fence.signal() }
            guard !pending.lost else { return }
            guard FileReviewPolicy.isNormalizedAbsolutePath(path), path != excluded, !path.hasPrefix(excluded + "/") else { return }
            // An alias event can change link count/content/ownership at other cached parents without changing those
            // directories' identities. The inventory's basic reader cannot repair that from clone-ledger state.
            if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsHardlink | kFSEventStreamEventFlagItemIsLastHardlink) != 0 {
                pending = Changes(lost: true); return
            }
            let recursive = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagItemIsDir) != 0
            if recursive { pending.recursive.insert(path) }
            pending.shallow.insert((path as NSString).deletingLastPathComponent)
            if pending.recursive.count + pending.shallow.count > 8192 { pending = Changes(lost: true) }
        }
    }

    func flush() -> (through: UInt64, changes: Changes) {
        if lock.withLock({ replaying }) {
            _ = history.wait(timeout: .now() + 1)
            let timedOut = lock.withLock { () -> Bool in
                guard replaying else { return false }
                pending = Changes(lost: true); replaying = false; return true
            }
            if timedOut {
                // Do not FlushSync an unbounded old backlog. A fresh stream fences the upcoming full live read instead.
                stop(); target = Target(); start(since: 0)
            }
        }
        // A delivered write fences kernel-to-daemon latency on this volume; FlushSync alone can run before a just-closed
        // file's event reaches the daemon. The snapshot cache is restricted to this same device.
        let pulse = directory.appendingPathComponent(".events-" + UUID().uuidString)
        while fence.wait(timeout: .now()) == .success {}
        lock.withLock { wantedFence = Self.canonical(pulse.path) }
        var observed = false
        do {
            let file = try PrivateFile(pulse)
            try file.write(Data())
            if let stream {
                FSEventStreamFlushSync(stream); queue.sync {}
                observed = fence.wait(timeout: .now() + 2) == .success
                FSEventStreamFlushSync(stream); queue.sync {}
            }
            try? file.remove()
        } catch { observed = false }
        return lock.withLock {
            wantedFence = nil
            var changes = pending; pending = Changes()
            if !running || !observed { changes = Changes(lost: true) }
            return (processedThrough, changes)
        }
    }
}
