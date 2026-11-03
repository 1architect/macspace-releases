import Foundation
import MacSpaceDiskMapPrivileged
import MacSpacePlatform

/// File metadata is persisted in SQLite; page projections load only the records they display.
struct DiskFile: Codable, Equatable, Sendable {
    var path: String
    var bytes: UInt64
    var logicalBytes: UInt64
    var ownerUID: UInt32?
    var ownershipID: UInt32?
    var modifiedAt: Date?
    var identity: FileReviewIdentity? = nil
    var duplicateVerification: DiskDuplicateVerification? = nil
    var retainedDuplicateKeeper: Bool = false
}
struct DiskDirectory: Codable, Equatable, Sendable {
    var path: String
    var folders: [String] = []
    var files: [DiskFile] = []
    var directBytes: UInt64 = 0
    var bytes: UInt64 = 0
    var readable = true
    var bundleIdentifier: String?
    var ownerUID: UInt32?
    var ownershipID: UInt32?
}
struct DiskIndex: Codable, Sendable {
    static let largeFileMinimum: UInt64 = 100_000_000
    var root: String
    var directories: [String: DiskDirectory] = [:]
    var eventID: UInt64 = 0
    var revision: UInt64 = 0
    var catalogRevision: UInt64?
    var ownershipClaims: [UInt32: DiskOwnershipClaim]?
    var volumeUsed: UInt64?
    var appPaths: [String]?
    /// Bundle identities encountered by the index, including system components and embedded extensions.
    var knownBundleIdentifiers: Set<String>?
    var measuredOwnershipBytes: [String: UInt64]?
    var browseVersion: Int?
    var storageRevision: Int?
    var summaryVersion: Int?
    var loadError: Bool?
    var duplicateBytes: UInt64?
    var duplicateCount: UInt64?
    var duplicateUnknown: Int?
    var duplicateFailure: Bool?
    var overviewFiles: [DiskFile]?
    var personalFolders: [DiskDirectory]?
    var categories: [DiskCategorySummary]?
    static let browseSchemaVersion = 4
    static let summarySchemaVersion = 3
    var largeFiles: [DiskFile] {
        directories.values.flatMap(\.files).filter { $0.logicalBytes >= Self.largeFileMinimum && $0.bytes > 0 }.sorted { ($0.logicalBytes, $0.path) > ($1.logicalBytes, $1.path) }
    }
    func contains(_ path: String, below folder: String) -> Bool { path == folder || path.hasPrefix(folder == "/" ? "/" : folder + "/") }
}
