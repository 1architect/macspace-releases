import Foundation
import Darwin
import MacSpacePlatform

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
    private let recordVisitedDirectories: Bool
    private var progress: ((Double) -> Void)?
    private let metadata: (String) -> stat?
    private var linksAtDirectory: [String: Set<String>] = [:]

    init(index: DiskIndex, excluded: [String] = [], recordVisitedDirectories: Bool = true, metadata: @escaping (String) -> stat? = { path in
        var info = stat(); return lstat(path, &info) == 0 ? info : nil
    }) {
        self.index = index; self.excluded = excluded; self.metadata = metadata
        self.recordVisitedDirectories = recordVisitedDirectories
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
        if recordVisitedDirectories { enumerated.insert(path) }
        let old = index.directories[path]
        var node = DiskDirectory(path: path)
        let previousLinks = linksAtDirectory[path] ?? []
        for key in previousLinks {
            index.hardlinks[key]?.removeAll { ($0.path as NSString).deletingLastPathComponent == path }
            if index.hardlinks[key]?.isEmpty == true { index.hardlinks.removeValue(forKey: key) }
        }
        linksAtDirectory.removeValue(forKey: path)
        var cancelled = false
        let complete = autoreleasepool {
            DirectoryWalk.entries(at: path) { name, entry in
                guard !Task.isCancelled else { cancelled = true; return }
                let child = path == "/" ? path + name : path + "/" + name
                guard !excluded.contains(where: { index.contains(child, below: $0) }), devices.contains(entry.device) else { return }
                if entry.isDirectory {
                    node.folders.append(child)
                } else if entry.isRegularFile, !entry.isDataless {
                    if name == "Info.plist", path.hasSuffix("/Contents") || path.hasSuffix("/Resources") {
                        node.bundleIdentifier = autoreleasepool { NSDictionary(contentsOfFile: child)?["CFBundleIdentifier"] as? String }
                    }
                    let bytes = entry.allocatedBytes, logical = entry.logicalBytes
                    if (entry.linkCount > 1 || !previousLinks.isEmpty), let st = metadata(child),
                       entry.linkCount > 1 || index.hardlinks["\(st.st_dev):\(st.st_ino)"] != nil {
                        let id = "\(st.st_dev):\(st.st_ino)"
                        if var aliases = index.hardlinks[id] {
                            for n in aliases.indices { aliases[n].bytes = bytes; aliases[n].logicalBytes = logical }
                            index.hardlinks[id] = aliases
                        }
                        linksAtDirectory[path, default: []].insert(id)
                        index.hardlinks[id, default: []].append(DiskFile(path: child, bytes: bytes, logicalBytes: logical))
                    } else {
                        node.directBytes += bytes
                        if logical >= DiskIndex.largeFileMinimum, bytes > 0 { node.files.append(DiskFile(path: child, bytes: bytes, logicalBytes: logical)) }
                    }
                }
            }
        }
        if cancelled { throw CancellationError() }
        if !complete {
            node = old ?? node
            node.readable = false
            index.directories[path] = node
            return
        }
        // Release the native buffer and Objective-C temporaries before descending.
        for (n, child) in node.folders.enumerated() {
            if path == index.root { progress?(Double(n) / Double(max(node.folders.count, 1))) }
            if recursive || index.directories[child] == nil { try read(child, recursive: true) }
        }
        for removed in Set(old?.folders ?? []).subtracting(node.folders) { remove(removed) }
        index.directories[path] = node
    }

    private mutating func remove(_ path: String) {
        // New cloud placeholders have nothing cached. Never walk the entire index for each one.
        var pending = [path]
        while let current = pending.popLast() {
            guard let node = index.directories.removeValue(forKey: current) else { continue }
            pending.append(contentsOf: node.folders)
            for key in linksAtDirectory.removeValue(forKey: current) ?? [] {
                index.hardlinks[key]?.removeAll { file in
                    guard let slash = file.path.lastIndex(of: "/") else { return false }
                    return String(file.path[..<slash]) == current
                }
                if index.hardlinks[key]?.isEmpty == true { index.hardlinks.removeValue(forKey: key) }
            }
        }
    }
}
