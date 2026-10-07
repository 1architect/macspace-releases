import Darwin
import Foundation

/// A macOS update downloaded and prepared by Software Update, waiting for a restart: its images on the Preboot volume
/// (`<volume group>/cryptex1/proposed`). System Settings counts it under macOS, with every volume of the startup container but Data,
/// not in System Data (Docs/Research.md); it installs at the next restart, and macOS removes it then.
public struct PreparedUpdate: Codable, Equatable, Sendable {
    /// "macOS 27.2 (26B5101f)", or "macOS update" when its manifest cannot be read.
    public var name: String
    public var bytes: UInt64
    public var path: String

    /// "macOS 27.2 update": the name without its build, for a chart's legend.
    public var shortName: String {
        let version = name.replacingOccurrences(of: #" \(.*\)$"#, with: "", options: .regularExpression)
        return version == "macOS update" ? String(localized: "macOS update") : String(localized: "\(version) update")
    }

    public init(name: String, bytes: UInt64, path: String) {
        self.name = name
        self.bytes = bytes
        self.path = path
    }

    /// Software Update in System Settings.
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension")!

    /// The prepared updates on the Preboot volume (one per volume group that has one).
    public static func find(preboot: String = "/System/Volumes/Preboot") -> [PreparedUpdate] {
        ((try? FileManager.default.contentsOfDirectory(atPath: preboot)) ?? []).compactMap { group in
            let proposed = (preboot as NSString).appendingPathComponent("\(group)/cryptex1/proposed")
            guard let bytes = uniqueAllocatedBytes(proposed), bytes > 0 else { return nil }
            let manifest = NSDictionary(contentsOfFile: (proposed as NSString).appendingPathComponent("BuildManifest.plist"))
            let version = [manifest?["ProductVersion"] as? String, (manifest?["ProductBuildVersion"] as? String).map { "(\($0))" }]
                .compactMap { $0 }.joined(separator: " ")
            return PreparedUpdate(name: version.isEmpty ? "macOS update" : "macOS \(version)", bytes: bytes, path: proposed)
        }
    }

    /// The space a folder's files take, each APFS clone family once (`ATTR_CMNEXT_CLONEID`): the update's images come in clone pairs
    /// (`os.dmg`/`os.clone.dmg`), which `du` counts twice. nil when the folder is missing or cannot be read.
    public static func uniqueAllocatedBytes(_ folder: String) -> UInt64? {
        guard FileManager.default.fileExists(atPath: folder), let root = strdup(folder) else { return nil }
        defer { free(root) }
        var paths: [UnsafeMutablePointer<CChar>?] = [root, nil]
        guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil) else { return nil }
        defer { fts_close(fts) }
        var list = attrlist(bitmapcount: u_short(ATTR_BIT_MAP_COUNT), reserved: 0, commonattr: 0, volattr: 0, dirattr: 0,
                            fileattr: attrgroup_t(ATTR_FILE_ALLOCSIZE), forkattr: attrgroup_t(ATTR_CMNEXT_CLONEID))
        var buffer = [UInt8](repeating: 0, count: 32)
        var families: [UInt64: UInt64] = [:]
        var loose: UInt64 = 0
        while let entry = fts_read(fts) {
            guard Int32(entry.pointee.fts_info) == FTS_F, let path = entry.pointee.fts_path else { continue }
            // Length, then the allocated size (file attributes), then the clone id (extended common attributes).
            let result = buffer.withUnsafeMutableBytes { getattrlist(path, &list, $0.baseAddress, $0.count, UInt32(FSOPT_NOFOLLOW | FSOPT_ATTR_CMN_EXTENDED)) }
            guard result == 0 else { continue }
            let allocated = buffer.withUnsafeBytes { UInt64(max($0.loadUnaligned(fromByteOffset: 4, as: Int64.self), 0)) }
            let clone = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 12, as: UInt64.self) }
            if clone == 0 { loose += allocated } else { families[clone] = max(families[clone] ?? 0, allocated) }
        }
        return loose + families.values.reduce(0, +)
    }
}
