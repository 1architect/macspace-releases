import Foundation
import MacSpacePlatform
import MacSpaceDiskMapPrivileged

/// Classification describes measured data; it never grants deletion eligibility.
enum DiskCategory: String, Codable, CaseIterable, Sendable {
    case archives, installers, documents, media, other, largeFiles
    var title: String {
        switch self {
        case .archives: loc("Archives")
        case .installers: loc("Installers")
        case .documents: loc("Documents")
        case .media: loc("Media")
        case .other: loc("Other")
        case .largeFiles: loc("Large files")
        }
    }
    static let inventoryCategories: [Self] = [.archives, .installers, .documents, .media, .other]
    static func inventoryCategory(_ path: String) -> Self {
        let ext = (path as NSString).pathExtension.lowercased()
        if ["dmg", "pkg", "mpkg", "iso"].contains(ext) { return .installers }
        if ["zip", "minizip", "gz", "bz2", "xz", "tar", "7z", "rar", "zst", "tgz"].contains(ext) { return .archives }
        if ["jpg", "jpeg", "png", "heic", "tiff", "gif", "raw", "mov", "mp4", "m4v", "mkv", "avi", "webm", "psd", "mp3", "m4a", "wav", "aiff", "flac", "ogg", "aac", "caf"].contains(ext) { return .media }
        if ["pdf", "doc", "docx", "odt", "rtf", "txt", "pages", "xls", "xlsx", "ods", "numbers", "ppt", "pptx", "odp", "key", "epub"].contains(ext) { return .documents }
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
    enum Kind: String, Codable, Sendable { case direct, category, duplicates, managed }
    var folder: String
    var kind: Kind
    var category: DiskCategory? = nil
    var largeType: String? = nil
    var includeSmaller: Bool = false
    var inFolder: Bool = false
    var selectionParent: String? = nil
    var fileType: String? = nil
    var focusPath: String? = nil
    var afterSize: UInt64? = nil
    var afterPath: String? = nil
    var pageID: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return "browse:" + ((try? encoder.encode(self)) ?? Data()).base64EncodedString()
    }
    var usesMetadataInventory: Bool {
        kind == .managed
    }
    var selectionScope: String {
        var inventory = self
        inventory.afterSize = nil; inventory.afterPath = nil; inventory.focusPath = nil
        return inventory.pageID
    }
    init(folder: String, kind: Kind, category: DiskCategory? = nil) {
        self.folder = folder; self.kind = kind; self.category = category
    }
    private enum CodingKeys: String, CodingKey { case folder, kind, category, largeType, includeSmaller, inFolder, selectionParent, fileType, focusPath, afterSize, afterPath }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        folder = try values.decode(String.self, forKey: .folder)
        kind = try values.decode(Kind.self, forKey: .kind)
        category = try values.decodeIfPresent(DiskCategory.self, forKey: .category)
        largeType = try values.decodeIfPresent(String.self, forKey: .largeType)
        includeSmaller = try values.decodeIfPresent(Bool.self, forKey: .includeSmaller) ?? false
        inFolder = try values.decodeIfPresent(Bool.self, forKey: .inFolder) ?? false
        selectionParent = try values.decodeIfPresent(String.self, forKey: .selectionParent)
        fileType = try values.decodeIfPresent(String.self, forKey: .fileType)
        focusPath = try values.decodeIfPresent(String.self, forKey: .focusPath)
        afterSize = try values.decodeIfPresent(UInt64.self, forKey: .afterSize)
        afterPath = try values.decodeIfPresent(String.self, forKey: .afterPath)
    }
    init?(id: String) {
        guard id.hasPrefix("browse:"), id.utf8.count <= 32_768, let data = Data(base64Encoded: String(id.dropFirst(7))),
              let decoded = try? JSONDecoder().decode(Self.self, from: data),
              DiskDatabase.contains(decoded.folder, below: "/"),
              decoded.selectionParent.map({ DiskDatabase.contains($0, below: decoded.folder) }) != false,
              decoded.focusPath.map({ DiskDatabase.contains($0, below: decoded.folder) }) != false,
              decoded.fileType.map({ DiskFileType.valid($0) }) != false,
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
    var types: [DiskTypeSummary] = []
    var totalsComplete: Bool = true
    var loadingFraction: Double? = nil
}

struct DiskDuplicateGroup: Sendable {
    var id: String
    var keeper: DiskFile
    var copies: [DiskFile]
    var verifications: [String: DiskDuplicateVerification] = [:]
    var copyCount: Int? = nil
    var totalBytes: UInt64? = nil
}

/// Stable content groups shared by browse, pagination and complete selection queries.
enum DiskFileType {
    static func key(_ path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        if ["jpg", "jpeg", "png", "heic", "tiff", "gif", "raw"].contains(ext) { return "images" }
        if ["mov", "mp4", "m4v", "mkv", "avi", "webm"].contains(ext) { return "video" }
        if ["mp3", "m4a", "wav", "aiff", "flac", "ogg", "aac", "caf"].contains(ext) { return "audio" }
        if ["doc", "docx", "odt", "rtf", "pages"].contains(ext) { return "text-documents" }
        if ["xls", "xlsx", "ods", "numbers"].contains(ext) { return "spreadsheets" }
        if ["ppt", "pptx", "odp", "key"].contains(ext) { return "presentations" }
        return valid(ext) && !ext.isEmpty ? "ext:" + ext : "other"
    }
    static func valid(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 64 && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == ":" || $0 == "-") }
    }
    static func title(_ key: String) -> String {
        switch key {
        case "images": loc("Images")
        case "video": loc("Videos")
        case "audio": loc("Audio")
        case "text-documents": loc("Text documents")
        case "spreadsheets": loc("Spreadsheets")
        case "presentations": loc("Presentations")
        case "ext:pdf": loc("PDF documents")
        case "ext:skp": loc("SketchUp projects")
        case "other": loc("Other formats")
        default: key.hasPrefix("ext:") ? loc("\(String(key.dropFirst(4)).uppercased()) files") : loc("Other formats")
        }
    }
}
struct DiskTypeSummary: Sendable {
    var key: String
    var count: UInt64
    var bytes: UInt64
}

/// Inspection is independent of deletion authority. Photo-library internals stay unselectable.
enum DiskManagedLibrary {
    static func contains(_ original: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> Bool {
        let path = FileReviewPolicy.livePath(original)
        guard FileReviewPolicy.personalFolders.contains(where: { path.hasPrefix(home + "/" + $0 + "/") }) else { return false }
        return path.split(separator: "/").contains { isLibraryName(String($0)) }
    }
    static func isLibraryName(_ name: String) -> Bool {
        ["photoslibrary", "photolibrary"].contains((name as NSString).pathExtension.lowercased())
    }
}
