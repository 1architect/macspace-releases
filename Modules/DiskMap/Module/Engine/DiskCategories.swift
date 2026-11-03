import Foundation
import MacSpaceDiskMapPrivileged

/// Classification describes measured data; it never grants deletion eligibility.
enum DiskCategory: String, Codable, CaseIterable, Sendable {
    case archives, installers, media, other, largeFiles
    var title: String {
        switch self {
        case .archives: loc("Archives")
        case .installers: loc("Installers")
        case .media: loc("Media")
        case .other: loc("Other")
        case .largeFiles: loc("Large files")
        }
    }
    static let inventoryCategories: [Self] = [.archives, .installers, .media, .other]
    static func inventoryCategory(_ path: String) -> Self {
        let ext = (path as NSString).pathExtension.lowercased()
        if ["dmg", "pkg", "mpkg", "iso"].contains(ext) { return .installers }
        if ["zip", "minizip", "gz", "bz2", "xz", "tar", "7z", "rar", "zst", "tgz"].contains(ext) { return .archives }
        if ["jpg", "jpeg", "png", "heic", "tiff", "gif", "raw", "mov", "mp4", "m4v", "mkv", "avi", "webm", "psd", "mp3", "m4a", "wav", "aiff", "flac", "ogg", "aac", "caf"].contains(ext) { return .media }
        return .other
    }
}

struct DiskCategorySummary: Codable, Sendable {
    var category: DiskCategory
    var bytes: UInt64
    var count: UInt64
}

/// Lazy, bounded database pages. The opaque cursor is stable for equal-size files too.
struct DiskBrowseRequest: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case direct, category, duplicates }
    var folder: String
    var kind: Kind
    var category: DiskCategory? = nil
    var largeType: String? = nil
    var includeSmaller: Bool = false
    var selectionParent: String? = nil
    var afterSize: UInt64? = nil
    var afterPath: String? = nil
    var pageID: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return "browse:" + ((try? encoder.encode(self)) ?? Data()).base64EncodedString()
    }
    var selectionScope: String {
        var inventory = self
        inventory.afterSize = nil; inventory.afterPath = nil
        return inventory.pageID
    }
    init(folder: String, kind: Kind, category: DiskCategory? = nil) {
        self.folder = folder; self.kind = kind; self.category = category
    }
    private enum CodingKeys: String, CodingKey { case folder, kind, category, largeType, includeSmaller, selectionParent, afterSize, afterPath }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        folder = try values.decode(String.self, forKey: .folder)
        kind = try values.decode(Kind.self, forKey: .kind)
        category = try values.decodeIfPresent(DiskCategory.self, forKey: .category)
        largeType = try values.decodeIfPresent(String.self, forKey: .largeType)
        includeSmaller = try values.decodeIfPresent(Bool.self, forKey: .includeSmaller) ?? false
        selectionParent = try values.decodeIfPresent(String.self, forKey: .selectionParent)
        afterSize = try values.decodeIfPresent(UInt64.self, forKey: .afterSize)
        afterPath = try values.decodeIfPresent(String.self, forKey: .afterPath)
    }
    init?(id: String) {
        guard id.hasPrefix("browse:"), id.utf8.count <= 32_768, let data = Data(base64Encoded: String(id.dropFirst(7))),
              let decoded = try? JSONDecoder().decode(Self.self, from: data),
              DiskDatabase.contains(decoded.folder, below: "/"),
              decoded.selectionParent.map({ DiskDatabase.contains($0, below: decoded.folder) }) != false,
              decoded.afterPath.map({ DiskDatabase.contains($0, below: decoded.folder) }) != false,
              (decoded.afterSize == nil) == (decoded.afterPath == nil) else { return nil }
        self = decoded
    }
}

struct DiskBrowsePage: Sendable {
    var request: DiskBrowseRequest
    var files: [DiskFile]
    var next: DiskBrowseRequest?
    var ownership: [String: DiskOwnershipClaim]
    var availableTypes: Set<String> = []
    var eligibleCount: UInt64 = 0
    var eligibleBytes: UInt64 = 0
    var unavailableReason: String? = nil
    var duplicateGroups: [DiskDuplicateGroup] = []
}

struct DiskDuplicateGroup: Sendable {
    var id: String
    var keeper: DiskFile
    var copies: [DiskFile]
    var verifications: [String: DiskDuplicateVerification] = [:]
}
