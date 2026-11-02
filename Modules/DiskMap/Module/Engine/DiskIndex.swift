import Foundation
import Darwin

/// Only directories and large files are retained. Small file bytes are still included in every folder total.
struct DiskFile: Codable, Equatable, Sendable {
    var path: String
    var bytes: UInt64
    var logicalBytes: UInt64
}
struct DiskDirectory: Codable, Equatable, Sendable {
    var path: String
    var folders: [String] = []
    var files: [DiskFile] = []
    var directBytes: UInt64 = 0
    var bytes: UInt64 = 0
    var readable = true
    var bundleIdentifier: String?
}
struct DiskIndex: Codable, Sendable {
    static let largeFileMinimum: UInt64 = 100_000_000
    var root: String
    var directories: [String: DiskDirectory] = [:]
    var eventID: UInt64 = 0
    var revision: UInt64 = 0
    var volumeUsed: UInt64?
    var hardlinks: [String: [DiskFile]] = [:]
    var largeFiles: [DiskFile] {
        let linked = hardlinks.values.compactMap { $0.sorted { $0.path < $1.path }.first }.filter { $0.logicalBytes >= Self.largeFileMinimum && $0.bytes > 0 }
        return (directories.values.flatMap(\.files).filter { $0.logicalBytes >= Self.largeFileMinimum && $0.bytes > 0 } + linked).sorted { ($0.logicalBytes, $0.path) > ($1.logicalBytes, $1.path) }
    }
    func contains(_ path: String, below folder: String) -> Bool { path == folder || path.hasPrefix(folder == "/" ? "/" : folder + "/") }
}

/// Shallow rereads of changed directories reuse all unchanged descendants. Only new/invalidated subtrees recurse.
struct DiskScanner {
    var index: DiskIndex
    let excluded: [String]
    private(set) var enumerated = Set<String>()
    private var devices = Set<dev_t>()
    private var progress: ((Double) -> Void)?
    private let metadata: (String) -> stat?
    private var linksAtDirectory: [String: Set<String>] = [:]

    init(index: DiskIndex, excluded: [String] = [], metadata: @escaping (String) -> stat? = { path in
        var info = stat(); return lstat(path, &info) == 0 ? info : nil
    }) {
        self.index = index; self.excluded = excluded; self.metadata = metadata
        for (id, files) in index.hardlinks {
            for file in files { linksAtDirectory[(file.path as NSString).deletingLastPathComponent, default: []].insert(id) }
        }
        if let st = metadata(index.root) { devices.insert(st.st_dev) }
        if index.root == "/", let st = metadata("/System/Volumes/Data") { devices.insert(st.st_dev) }
    }

    mutating func scan(changed: Set<String>, recursive: Set<String> = [], progress: ((Double) -> Void)? = nil) throws -> DiskIndex {
        self.progress = progress
        progress?(0)
        let initial = index.directories[index.root] == nil
        let branches = initial ? [index.root] : recursive.sorted { $0.count < $1.count }
        var covered: [String] = []
        for path in branches where !covered.contains(where: { index.contains(path, below: $0) }) {
            try read(path, recursive: true); covered.append(path)
        }
        let paths = changed.filter { path in !covered.contains(where: { index.contains(path, below: $0) }) }.sorted()
        for (n, path) in paths.enumerated() {
            try read(path, recursive: false)
            progress?(Double(n + 1) / Double(max(paths.count, 1)))
        }
        // A hard link belongs to one directory in the map. Retain all aliases so deleting its old owner
        // transfers accounting to another link without rereading that untouched branch.
        var linkedBytes: [String: UInt64] = [:]
        for links in index.hardlinks.values {
            if let first = links.sorted(by: { $0.path < $1.path }).first { linkedBytes[(first.path as NSString).deletingLastPathComponent, default: 0] += first.bytes }
        }
        // No filesystem reads: recalculate parent totals deepest first.
        for path in index.directories.keys.sorted(by: { $0.count > $1.count }) {
            guard var node = index.directories[path] else { continue }
            node.bytes = node.folders.reduce(node.directBytes + (linkedBytes[path] ?? 0)) { $0 + (index.directories[$1]?.bytes ?? 0) }
            index.directories[path] = node
        }
        progress?(1)
        return index
    }

    private mutating func read(_ path: String, recursive: Bool) throws {
        try Task.checkCancellation()
        guard index.contains(path, below: index.root), !excluded.contains(where: { index.contains(path, below: $0) }) else { return }
        guard let info = metadata(path), info.st_mode & S_IFMT == S_IFDIR, devices.contains(info.st_dev) else {
            if errno == ENOENT { remove(path) }
            return
        }
        if info.st_flags & UInt32(SF_DATALESS) != 0 {
            remove(path)
            index.directories[path] = DiskDirectory(path: path)
            return
        }
        enumerated.insert(path)
        let urls: [URL]
        do { urls = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path), includingPropertiesForKeys: nil) }
        catch {
            var node = index.directories[path] ?? DiskDirectory(path: path)
            node.readable = false; index.directories[path] = node
            return
        }
        let old = index.directories[path]
        var node = DiskDirectory(path: path)
        for key in linksAtDirectory[path] ?? [] {
            index.hardlinks[key]?.removeAll { ($0.path as NSString).deletingLastPathComponent == path }
            if index.hardlinks[key]?.isEmpty == true { index.hardlinks.removeValue(forKey: key) }
        }
        linksAtDirectory[path] = []
        for (n, url) in urls.enumerated() {
            if path == index.root { progress?(Double(n) / Double(max(urls.count, 1))) }
            try Task.checkCancellation()
            // Foundation can canonicalize /var to /private/var in returned URLs. Keep one spelling throughout the index.
            let child = (path as NSString).appendingPathComponent(url.lastPathComponent)
            guard !excluded.contains(where: { index.contains(child, below: $0) }), let st = metadata(child), devices.contains(st.st_dev) else { continue }
            switch st.st_mode & S_IFMT {
            case S_IFDIR:
                node.folders.append(child)
                if recursive || index.directories[child] == nil { try read(child, recursive: true) }
            case S_IFREG:
                guard st.st_flags & UInt32(SF_DATALESS) == 0 else { continue }
                // APFS allocation excludes dataless cloud content. Reading metadata never downloads a file.
                if url.lastPathComponent == "Info.plist", path.hasSuffix("/Contents") || path.hasSuffix("/Resources") { node.bundleIdentifier = NSDictionary(contentsOf: url)?["CFBundleIdentifier"] as? String }
                let bytes = UInt64(max(0, st.st_blocks)) * 512
                let logical = UInt64(max(0, st.st_size))
                if st.st_nlink > 1 || index.hardlinks["\(st.st_dev):\(st.st_ino)"] != nil {
                    let id = "\(st.st_dev):\(st.st_ino)"
                    if var aliases = index.hardlinks[id] {
                        for n in aliases.indices { aliases[n].bytes = bytes; aliases[n].logicalBytes = logical }
                        index.hardlinks[id] = aliases
                    }
                    linksAtDirectory[path, default: []].insert(id)
                    index.hardlinks[id, default: []].append(DiskFile(path: child, bytes: bytes, logicalBytes: logical))
                    continue
                }
                node.directBytes += bytes
                if logical >= DiskIndex.largeFileMinimum, bytes > 0 { node.files.append(DiskFile(path: child, bytes: bytes, logicalBytes: logical)) }
            case S_IFLNK:
                // Never traverse aliases, firmlinks or another volume.
                node.directBytes += UInt64(max(0, st.st_blocks)) * 512
            default: break
            }
        }
        for removed in Set(old?.folders ?? []).subtracting(node.folders) { remove(removed) }
        index.directories[path] = node
    }

    private mutating func remove(_ path: String) {
        for key in Array(index.hardlinks.keys) {
            index.hardlinks[key]?.removeAll { $0.path == path || $0.path.hasPrefix(path + "/") }
            if index.hardlinks[key]?.isEmpty == true { index.hardlinks.removeValue(forKey: key) }
        }
        for key in index.directories.keys.filter({ index.contains($0, below: path) }) { index.directories.removeValue(forKey: key) }
    }
}
