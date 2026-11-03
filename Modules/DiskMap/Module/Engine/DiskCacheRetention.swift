import Foundation

/// A completed index is retained; interrupted and retired generations are disposable cache data.
enum DiskCacheRetention {
    static func prune(base: URL, keeping: Set<URL>) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: base.deletingLastPathComponent().path) else { return }
        for file in try fm.contentsOfDirectory(at: base.deletingLastPathComponent(), includingPropertiesForKeys: [.isRegularFileKey]) {
            let name = file.lastPathComponent
            let stem = name.hasSuffix("-wal") || name.hasSuffix("-shm") ? String(name.dropLast(4)) : name
            let suffix = stem.hasPrefix(base.lastPathComponent + ".") ? String(stem.dropFirst(base.lastPathComponent.count + 1)) : ""
            let legacy = base.lastPathComponent == "Index-v3.sqlite" && name == "Index-v2.scan"
            guard legacy || UUID(uuidString: suffix) != nil || stem == base.lastPathComponent else { continue }
            guard !keeping.contains(where: { $0.lastPathComponent == stem }), try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            try fm.removeItem(at: file)
        }
    }
}
