import Foundation
import MacSpacePlatform

/// What the helper measures for System Data: places only root can read. Read-only; the list is fixed, so the helper never
/// sizes a path a caller makes up.
public struct RootMeasurementResponse: Codable, Equatable, Sendable {
    public let sizes: [String: UInt64]

    public init(sizes: [String: UInt64]) { self.sizes = sizes }
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
}

public struct SystemDataPrivilegedOperations: PrivilegedOperationHandler {
    public static let measure = "systemdata.measure"
    public static let deleteVersions = "systemdata.versions.delete"

    public init() {}

    public var operations: Set<String> { [Self.measure, Self.deleteVersions] }

    public func handle(_ operation: String, arguments: [String: String], caller: PrivilegedCaller) throws -> Data {
        if operation == Self.deleteVersions { return try JSONEncoder().encode(VersionStoreCleaner().execute()) }
        guard operation == Self.measure else { throw PrivilegedOperationError("Unknown operation \(operation).") }
        let requested = (arguments["paths"] ?? "").split(separator: "\n").map(String.init)
        let sizer = FileTreeSizer()
        var sizes: [String: UInt64] = [:]
        for path in requested where RootMeasuredLocations.allowed.contains(path) {
            guard FileManager.default.fileExists(atPath: path), (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil,
                  let measured = sizer.size(at: URL(fileURLWithPath: path)) else { continue }
            sizes[path] = measured.allocatedBytesEstimate ?? measured.logicalBytes
        }
        return try JSONEncoder().encode(RootMeasurementResponse(sizes: sizes))
    }
}
