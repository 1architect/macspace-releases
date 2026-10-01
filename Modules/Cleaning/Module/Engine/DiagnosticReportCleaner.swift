import Foundation

public struct CleanupCandidate: Codable, Equatable, Sendable {
    public let path: String
    /// File extension, e.g. `spin` (spindump), `hang`, `diag`, `ips` (crash).
    public let kind: String
    public let bytes: UInt64
    public let modifiedAt: Date
}

public struct CleanupPlan: Codable, Equatable, Sendable {
    public let olderThanDays: Int
    public let cutoff: Date
    public let candidates: [CleanupCandidate]
    public let totalBytes: UInt64
    /// Report directories that could not be listed.
    public let unreadableDirectories: [String]
}

public struct CleanupResult: Codable, Equatable, Sendable {
    public let plan: CleanupPlan
    public let deleted: [String]
    /// Path -> reason.
    public let failed: [String: String]
    public let freedBytes: UInt64
}

/// Deletes old diagnostic reports (spindump `.spin`/`.hang`, `.diag`, crash `.ips`, …). Reports are write-once
/// records of past events that nothing on the system reads back, so this is cleanup, not a control: it is not
/// journaled and cannot be undone.
public struct DiagnosticReportCleaner {
    public static let reportExtensions: Set<String> = [
        "spin", "hang", "diag", "ips", "cpu_resource", "shutdownStall", "crash", "panic", "core_analytics", "anon_system_stats",
    ]
    public static let defaultOlderThanDays = 7

    public let directories: [String]
    private let fileManager: FileManager

    public init(directories: [String], fileManager: FileManager = .default) {
        self.directories = directories
        self.fileManager = fileManager
    }

    /// The system and user report folders, including the system `Retired` folder of submitted analytics.
    public static func standardDirectories(home: URL?) -> [String] {
        var directories = ["/Library/Logs/DiagnosticReports", "/Library/Logs/DiagnosticReports/Retired"]
        if let home { directories.append(home.appendingPathComponent("Library/Logs/DiagnosticReports").path) }
        return directories
    }

    public func plan(olderThanDays days: Int, now: Date = Date()) -> CleanupPlan {
        let cutoff = now.addingTimeInterval(-Double(max(0, days)) * 86_400)
        var candidates: [CleanupCandidate] = []
        var unreadable: [String] = []
        for directory in directories {
            guard let names = try? fileManager.contentsOfDirectory(atPath: directory) else {
                if fileManager.fileExists(atPath: directory) { unreadable.append(directory) }
                continue
            }
            for name in names {
                let kind = (name as NSString).pathExtension
                guard Self.reportExtensions.contains(kind) else { continue }
                let path = (directory as NSString).appendingPathComponent(name)
                guard let attributes = try? fileManager.attributesOfItem(atPath: path),
                      attributes[.type] as? FileAttributeType == .typeRegular,
                      let modified = attributes[.modificationDate] as? Date, modified < cutoff else { continue }
                candidates.append(CleanupCandidate(path: path, kind: kind, bytes: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
                                                   modifiedAt: modified))
            }
        }
        candidates.sort { $0.bytes > $1.bytes }
        return CleanupPlan(olderThanDays: days, cutoff: cutoff, candidates: candidates,
                           totalBytes: candidates.reduce(0) { $0 + $1.bytes }, unreadableDirectories: unreadable)
    }

    /// Deletes the planned files, re-checking each one is still an old regular report file.
    public func execute(_ plan: CleanupPlan) -> CleanupResult {
        var deleted: [String] = []
        var failed: [String: String] = [:]
        var freed: UInt64 = 0
        for candidate in plan.candidates {
            guard let attributes = try? fileManager.attributesOfItem(atPath: candidate.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let modified = attributes[.modificationDate] as? Date, modified < plan.cutoff else {
                failed[candidate.path] = "Changed or removed since the plan; skipped."
                continue
            }
            do {
                try fileManager.removeItem(atPath: candidate.path)
                deleted.append(candidate.path)
                freed += candidate.bytes
            } catch {
                failed[candidate.path] = (error as NSError).localizedDescription
            }
        }
        return CleanupResult(plan: plan, deleted: deleted, failed: failed, freedBytes: freed)
    }
}
