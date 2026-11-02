import Foundation
import Darwin

/// Query data built once per completed measurement, shared by tile, root and navigation pages.
struct DiskSnapshot: Sendable {
    let index: DiskIndex
    let files: [DiskFile]
    init(_ index: DiskIndex) {
        self.index = index
        // Upgrade legacy cache eligibility with O(large files) metadata reads, not a new whole-disk walk.
        files = index.largeFiles.map { value in
            var value = value
            if value.ownerUID == nil {
                var info = stat()
                if lstat(value.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_flags & UInt32(SF_DATALESS) == 0 { value.ownerUID = info.st_uid }
            }
            return value
        }
    }
}

/// At most one write and one latest pending snapshot. Disk I/O never holds the navigation actor.
actor DiskCacheWriter {
    private let url: URL
    private var pending: DiskIndex?
    private var worker: Task<Void, Never>?
    private var latest: UInt64 = 0
    init(url: URL) { self.url = url }
    func submit(_ index: DiskIndex) {
        guard index.revision >= latest else { return }
        latest = index.revision; pending = index
        guard worker == nil else { return }
        worker = Task { await drain() }
    }
    private func drain() async {
        while let next = pending {
            pending = nil
            let destination = url
            await Task.detached(priority: .utility) { try? DiskCache.write(next, to: destination) }.value
        }
        worker = nil
    }
    func flush() async { await worker?.value }
}
