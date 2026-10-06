import Foundation
import MacSpacePlatform

/// What the helper measures for System Data: places only root can read. Read-only; the list is fixed, so the helper never
/// sizes a path a caller makes up.
public struct RootMeasurementResponse: Codable, Equatable, Sendable {
    public let sizes: [String: UInt64]
    /// Of each size, the files flagged purgeable; absent from a helper of an earlier version.
    public let purgeable: [String: UInt64]?

    public init(sizes: [String: UInt64], purgeable: [String: UInt64]? = nil) {
        self.sizes = sizes
        self.purgeable = purgeable
    }
}

public enum RootMeasuredLocations {
    public static let allowed: Set<String> = [
        "/System/Volumes/Data/.Spotlight-V100",
        "/System/Volumes/Data/.DocumentRevisions-V100",
        "/System/Library/Caches/com.apple.coresymbolicationd",
        "/private/var/db/diagnostics",
        "/private/var/db/uuidtext",
        "/private/var/db/powerlog",
        "/private/var/vm",
        "/System/Volumes/Data/macOS Install Data",
        "/Library/Logs/DiagnosticReports",
    ]

    /// Anything under these roots may be measured too: the scan covers whatever is there, on any Mac, and part of it only root can
    /// read. Sizes only, and never outside the system's own folders (no home folder).
    public static let allowedRoots = ["/private/var/", "/private/tmp/", "/Library/", "/System/Library/", "/System/Volumes/Data/", "/opt/"]

    public static func isAllowed(_ path: String) -> Bool {
        if allowed.contains(path) { return true }
        guard !path.contains("/../"), !path.hasSuffix("/.."), !path.hasPrefix("/System/Volumes/Data/Users") else { return false }
        return allowedRoots.contains { path.hasPrefix($0) && path.count > $0.count }
    }
}

public struct SystemDataPrivilegedOperations: PrivilegedOperationHandler {
    public static let measure = "systemdata.measure"
    public static let deleteVersions = "systemdata.versions.delete"
    public static let deleteStagedUpdate = "systemdata.staged-update.delete"

    public init() {}

    public var operations: Set<String> { [Self.measure, Self.deleteVersions, Self.deleteStagedUpdate] }

    public func handle(_ operation: String, arguments: [String: String], caller: PrivilegedCaller) throws -> Data {
        if operation == Self.deleteStagedUpdate { return try JSONEncoder().encode(StagedUpdateCleaner().execute()) }
        if operation == Self.deleteVersions { return try JSONEncoder().encode(VersionStoreCleaner().execute()) }
        guard operation == Self.measure else { throw PrivilegedOperationError("Unknown operation \(operation).") }
        let requested = (arguments["paths"] ?? "").split(separator: "\n").map(String.init)
        let sizer = FileTreeSizer(countsPurgeable: true)
        var sizes: [String: UInt64] = [:]
        var purgeable: [String: UInt64] = [:]
        for path in requested where RootMeasuredLocations.isAllowed(path) {
            guard FileManager.default.fileExists(atPath: path), (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil,
                  let measured = sizer.size(at: URL(fileURLWithPath: path)) else { continue }
            sizes[path] = measured.allocatedBytesEstimate ?? measured.logicalBytes
            purgeable[path] = measured.purgeableBytes
        }
        return try JSONEncoder().encode(RootMeasurementResponse(sizes: sizes, purgeable: purgeable))
    }
}
