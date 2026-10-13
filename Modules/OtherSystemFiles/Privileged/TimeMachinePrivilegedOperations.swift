import Foundation
import MacSpacePlatform

/// Deletes backups from a connected Time Machine backup disk with `tmutil delete`, which needs root. The caller names the disk and
/// the backups; the helper checks each against what it reads itself: the disk must be one Time Machine uses and is connected now,
/// every backup must be on it, the newest backup is never deleted, and nothing is deleted while a backup runs or while that is unknown.
public struct BackupDeletionResult: Codable, Equatable, Sendable {
    public let executed: Bool
    /// Stamps no longer listed on the disk afterwards.
    public let deleted: [String]
    /// Stamps still listed, or refused, with why.
    public let kept: [String: String]
    public let freeBytesBefore: UInt64?
    public let freeBytesAfter: UInt64?
    public let error: String?

    public init(executed: Bool, deleted: [String], kept: [String: String], freeBytesBefore: UInt64?, freeBytesAfter: UInt64?, error: String?) {
        self.executed = executed
        self.deleted = deleted
        self.kept = kept
        self.freeBytesBefore = freeBytesBefore
        self.freeBytesAfter = freeBytesAfter
        self.error = error
    }
}

public struct BackupDeleter {
    let runner: any CommandRunning
    let destinations: () -> [TimeMachine.Destination]?
    let backups: (String) -> [TimeMachine.Backup]?
    let isBackingUp: () -> Bool?
    let free: (String) -> UInt64?

    public init(runner: any CommandRunning = ProcessCommandRunner(defaultTimeout: 600),
                destinations: (() -> [TimeMachine.Destination]?)? = nil,
                backups: ((String) -> [TimeMachine.Backup]?)? = nil,
                isBackingUp: (() -> Bool?)? = nil,
                free: ((String) -> UInt64?)? = nil) {
        self.runner = runner
        self.destinations = destinations ?? { TimeMachine.destinations() }
        self.backups = backups ?? { TimeMachine.backups(at: $0) }
        self.isBackingUp = isBackingUp ?? { TimeMachine.isBackingUp() }
        self.free = free ?? { TimeMachine.capacity(of: $0)?.free }
    }

    private func refused(_ why: String) -> BackupDeletionResult {
        BackupDeletionResult(executed: false, deleted: [], kept: [:], freeBytesBefore: nil, freeBytesAfter: nil, error: why)
    }

    public func execute(mountPoint: String, stamps: [String]) -> BackupDeletionResult {
        guard let known = destinations() else { return refused("Time Machine's backup disks could not be read.") }
        guard known.contains(where: { $0.mountPoint == mountPoint }) else { return refused("\(mountPoint) is not a connected Time Machine backup disk.") }
        guard isBackingUp() == false else { return refused("A backup is running, or its state could not be read. Nothing was deleted.") }
        guard let listed = backups(mountPoint), let newest = listed.last else { return refused("The backups on \(mountPoint) could not be read.") }
        let onDisk = Set(listed.map(\.stamp))
        var kept: [String: String] = [:]
        var chosen: [String] = []
        for stamp in Set(stamps).sorted() {
            if TimeMachine.date(fromStamp: stamp) == nil { kept[stamp] = "Not a backup's date."; continue }
            if !onDisk.contains(stamp) { kept[stamp] = "Not on the disk."; continue }
            if stamp == newest.stamp { kept[stamp] = "The latest backup is kept."; continue }
            chosen.append(stamp)
        }
        guard !chosen.isEmpty else {
            return BackupDeletionResult(executed: false, deleted: [], kept: kept, freeBytesBefore: nil, freeBytesAfter: nil, error: "No backup could be deleted.")
        }
        let before = free(mountPoint)
        var error: String?
        do {
            let result = try runner.run(TimeMachine.tool, ["delete", "-d", mountPoint] + chosen.flatMap { ["-t", $0] })
            if result.exitCode != 0 {
                let words = String(decoding: result.stderr + result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                error = "tmutil delete failed (\(result.exitCode))\(words.isEmpty ? "" : ": \(words)")."
            }
        } catch let failure {
            error = "tmutil delete did not run: \(failure.localizedDescription)"
        }
        // What went is read back from the disk, not from tmutil's answer.
        let after = Set((backups(mountPoint) ?? listed).map(\.stamp))
        let deleted = chosen.filter { !after.contains($0) }
        for stamp in chosen where after.contains(stamp) { kept[stamp] = "Still on the disk." }
        return BackupDeletionResult(executed: !deleted.isEmpty, deleted: deleted, kept: kept, freeBytesBefore: before, freeBytesAfter: free(mountPoint),
                                    error: error)
    }
}

public struct TimeMachinePrivilegedOperations: PrivilegedOperationHandler {
    public static let deleteBackups = "timemachine.backups.delete"

    public init() {}

    public var operations: Set<String> { [Self.deleteBackups] }
    public var readOnlyOperations: Set<String> { [] }

    /// `mountPoint`: the backup disk; `stamps`: the backups, one per line.
    public func handle(_ operation: String, arguments: [String: String], caller: PrivilegedCaller) throws -> Data {
        guard operation == Self.deleteBackups else { throw PrivilegedOperationError("Unknown operation \(operation).") }
        let stamps = (arguments["stamps"] ?? "").split(separator: "\n").map(String.init)
        return try JSONEncoder().encode(BackupDeleter().execute(mountPoint: arguments["mountPoint"] ?? "", stamps: stamps))
    }
}
