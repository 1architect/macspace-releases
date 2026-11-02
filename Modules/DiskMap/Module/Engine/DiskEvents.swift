import Foundation
import CoreServices

/// FSEvents replays changes since the persisted index watermark, including changes while MacSpace was closed.
final class DiskEvents: @unchecked Sendable {
    struct Changes: Sendable { var shallow = Set<String>(); var recursive = Set<String>() }
    private let lock = NSLock()
    private var pending = Changes()
    private var stream: FSEventStreamRef?
    private let root: String
    private let excluded: [String]
    private let queue = DispatchQueue(label: "com.macspace.disk-map.events", qos: .utility)

    init(root: String, since: UInt64, excluded: [String]) {
        self.root = root; self.excluded = excluded
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
        var path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
        if root == "/", path == "/System/Volumes/Data" || path.hasPrefix("/System/Volumes/Data/") { path = String(path.dropFirst("/System/Volumes/Data".count)); if path.isEmpty { path = "/" } }
        guard root == "/" || path == root || path.hasPrefix(root + "/"), !excluded.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { return }
        lock.withLock {
            let lost = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)
            if flags & lost != 0 { pending.recursive.insert(path) }
            else if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0 { pending.shallow.insert(path) }
            let parent = (path as NSString).deletingLastPathComponent
            if root == "/" || parent == root || parent.hasPrefix(root + "/") { pending.shallow.insert(parent) }
        }
    }
    func flush() { if let stream { FSEventStreamFlushSync(stream) } }
}
