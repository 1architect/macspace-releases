import Darwin
import Foundation
import MacSpacePlatform

/// Time Machine as `tmutil` and `diskutil` show it: the local snapshots on this Mac, the backup disks, and the backups on a backup disk
/// that is connected. Read as the user; only deleting backups on a backup disk needs root (`TimeMachinePrivilegedOperations`).
///
/// Measured on 26B5101f (2026-10-13), as an admin user without Full Disk Access: `tmutil localsnapshot`, `listlocalsnapshots /` and
/// `deletelocalsnapshots <date>` work without a password. Two snapshots held 1.72 GB (deleting them freed 602 MB and 1.12 GB); macOS's
/// purge service for them (`com.apple.TMCacheDelete`) reported 1.69 GB at urgency 3 and 4, 0 at 1 and 2, and only a minute after the
/// snapshots were made, and it still reported 1.72 GB once both were gone. Neither tool gives one snapshot's size.
public enum TimeMachine {
    public static let tool = "/usr/bin/tmutil"
    public static let diskutil = "/usr/sbin/diskutil"
    static let snapshotPrefix = "com.apple.TimeMachine."

    /// `yyyy-MM-dd-HHmmss`, the form `tmutil` names and deletes snapshots and backups by, read in the given time zone. nil for anything
    /// else, so a name that is not a stamp is never shown or deleted.
    public static func date(fromStamp stamp: String, timeZone: TimeZone = .current) -> Date? {
        let parts = stamp.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2, parts[3].count == 6,
              parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]), let time = Int(parts[3]) else { return nil }
        let hour = time / 10_000, minute = time / 100 % 100, second = time % 100
        guard (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 60 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        // A day the month does not have would roll over into the next month.
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)),
              calendar.component(.day, from: date) == day else { return nil }
        return date
    }

    /// The stamp in a snapshot's or a backup's name: `com.apple.TimeMachine.2026-10-13-025134.local`, `2026-10-01-120000.backup`
    /// or a backup folder named `2026-10-01-120000`.
    public static func stamp(inName name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let rest = trimmed.hasPrefix(snapshotPrefix) ? String(trimmed.dropFirst(snapshotPrefix.count)) : trimmed
        let stamp = String(rest.prefix { $0 != "." })
        return date(fromStamp: stamp) == nil ? nil : stamp
    }

    // MARK: Local snapshots

    /// One local snapshot of this Mac. Time Machine takes one an hour and keeps each for a day, so files can be restored without the
    /// backup disk; the one ending in `.backup` is the snapshot of the last backup to a backup disk, which the next backup starts from.
    public struct LocalSnapshot: Codable, Equatable, Sendable {
        public let name: String
        public let stamp: String
        public let date: Date

        public var isFromLastBackup: Bool { name.hasSuffix(".backup") }
    }

    /// The local snapshots, oldest first, and which of them Free leaves: the newest one, and the newest from a backup. Without the
    /// second, the next backup cannot start from it and takes far longer; a backup that is running reads the newest. Deleting by
    /// stamp removes every snapshot with that stamp, so one sharing a kept one's stamp is kept too. Purge (jithin-sabu/purge-app) keeps
    /// the same two.
    public struct LocalSnapshots: Codable, Equatable, Sendable {
        public let all: [LocalSnapshot]

        public init(_ snapshots: [LocalSnapshot]) {
            all = snapshots.sorted { $0.date != $1.date ? $0.date < $1.date : $0.name < $1.name }
        }

        public var keptStamps: Set<String> {
            var kept = Set<String>()
            if let newest = all.last { kept.insert(newest.stamp) }
            if let lastBackup = all.last(where: \.isFromLastBackup) { kept.insert(lastBackup.stamp) }
            return kept
        }

        public var removable: [LocalSnapshot] {
            let kept = keptStamps
            return all.filter { !kept.contains($0.stamp) }
        }

        public var kept: [LocalSnapshot] {
            let kept = keptStamps
            return all.filter { kept.contains($0.stamp) }
        }
    }

    /// `tmutil listlocalsnapshots /`: Time Machine's snapshots only. The list can also hold the snapshots macOS makes for its updates
    /// (`com.apple.os.update-…`), which `tmutil` cannot delete and which are not Time Machine's.
    public static func parseLocalSnapshots(_ output: String, timeZone: TimeZone = .current) -> LocalSnapshots {
        LocalSnapshots(output.split(whereSeparator: \.isNewline).compactMap { line -> LocalSnapshot? in
            let name = line.trimmingCharacters(in: .whitespaces)
            guard name.hasPrefix(snapshotPrefix) else { return nil }
            let stamp = String(name.dropFirst(snapshotPrefix.count).prefix { $0 != "." })
            guard let date = date(fromStamp: stamp, timeZone: timeZone) else { return nil }
            return LocalSnapshot(name: name, stamp: stamp, date: date)
        })
    }

    /// nil when `tmutil` could not be asked, which is not the same as no snapshots.
    public static func localSnapshots(runner: any CommandRunning = ProcessCommandRunner(defaultTimeout: 15)) -> LocalSnapshots? {
        guard let result = try? runner.run(tool, ["listlocalsnapshots", "/"]), result.exitCode == 0 else { return nil }
        return parseLocalSnapshots(String(decoding: result.stdout, as: UTF8.self))
    }

    /// Deletes these local snapshots, one stamp at a time (`tmutil deletelocalsnapshots <stamp>`), never the volume-wide form, which
    /// would take the kept ones too. What was deleted is read back from the list, not from `tmutil`'s answers.
    public static func deleteLocalSnapshots(_ stamps: [String], runner: any CommandRunning = ProcessCommandRunner(defaultTimeout: 120)) -> [String: String] {
        var failures: [String: String] = [:]
        for stamp in stamps where date(fromStamp: stamp) != nil {
            do {
                let result = try runner.run(tool, ["deletelocalsnapshots", stamp])
                if result.exitCode != 0 {
                    failures[stamp] = String(decoding: result.stderr + result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } catch {
                failures[stamp] = error.localizedDescription
            }
        }
        return failures
    }

    // MARK: Backup disks

    /// A backup disk Time Machine is set to use. `mountPoint` only while it is connected (a network disk only during a backup).
    public struct Destination: Codable, Equatable, Sendable {
        public let id: String
        public let name: String
        /// "Local" or "Network", as `tmutil` says.
        public let kind: String
        public let mountPoint: String?

        public init(id: String, name: String, kind: String, mountPoint: String?) {
            self.id = id
            self.name = name
            self.kind = kind
            self.mountPoint = mountPoint
        }
    }

    /// `tmutil destinationinfo`: blocks of `Key : value` lines, one per disk, between lines of `=`. The man page documents Name, Kind,
    /// URL, Mount Point and ID; the last disk used is marked with `>`.
    public static func parseDestinations(_ output: String) -> [Destination] {
        var destinations: [Destination] = []
        var fields: [String: String] = [:]
        func flush() {
            if let id = fields["ID"], !id.isEmpty {
                destinations.append(Destination(id: id, name: fields["Name"] ?? id, kind: fields["Kind"] ?? "",
                                                mountPoint: fields["Mount Point"].flatMap { $0.hasPrefix("/") ? $0 : nil }))
            }
            fields = [:]
        }
        for line in output.split(whereSeparator: \.isNewline).map(String.init) {
            if line.hasPrefix("==") { flush(); continue }
            guard let colon = line.range(of: " : ") ?? line.range(of: ": ") else { continue }
            var key = String(line[..<colon.lowerBound]).trimmingCharacters(in: .whitespaces)
            if key.hasPrefix(">") { key = key.dropFirst().trimmingCharacters(in: .whitespaces) }
            fields[key] = String(line[colon.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        flush()
        return destinations
    }

    /// The backup disks; empty when there are none, nil when `tmutil` could not be asked.
    public static func destinations(runner: any CommandRunning = ProcessCommandRunner(defaultTimeout: 15)) -> [Destination]? {
        guard let result = try? runner.run(tool, ["destinationinfo"]) else { return nil }
        let text = String(decoding: result.stdout + result.stderr, as: UTF8.self)
        if text.contains("No destinations configured") { return [] }
        guard result.exitCode == 0 else { return nil }
        return parseDestinations(text)
    }

    /// One backup on a backup disk.
    public struct Backup: Codable, Equatable, Sendable {
        public let stamp: String
        public let date: Date

        public init(stamp: String, date: Date) {
            self.stamp = stamp
            self.date = date
        }
    }

    /// The backups on a connected backup disk, oldest first: on an APFS disk (macOS 11 and later) each backup is a snapshot of the disk
    /// (`diskutil apfs listSnapshots`); on an older Mac OS Extended disk, a folder in `Backups.backupdb/<computer>`. Both read without
    /// root. nil when neither could be read.
    public static func backups(at mountPoint: String, runner: any CommandRunning = ProcessCommandRunner(defaultTimeout: 30),
                               fileManager: FileManager = .default) -> [Backup]? {
        if let result = try? runner.run(diskutil, ["apfs", "listSnapshots", "-plist", mountPoint]), result.exitCode == 0,
           let backups = parseSnapshotList(result.stdout), !backups.isEmpty {
            return backups
        }
        let database = (mountPoint as NSString).appendingPathComponent("Backups.backupdb")
        guard let computers = try? fileManager.contentsOfDirectory(atPath: database) else { return nil }
        var found: [Backup] = []
        for computer in computers where !computer.hasPrefix(".") {
            let folder = (database as NSString).appendingPathComponent(computer)
            // A finished backup is a folder named by its stamp; one still being made ends in `.inProgress`, and `Latest` is a link.
            for name in (try? fileManager.contentsOfDirectory(atPath: folder)) ?? [] {
                guard let date = date(fromStamp: name) else { continue }
                found.append(Backup(stamp: name, date: date))
            }
        }
        return found.sorted { $0.date < $1.date }
    }

    /// The Time Machine backups among a disk's snapshots (`diskutil apfs listSnapshots -plist`), oldest first.
    public static func parseSnapshotList(_ data: Data) -> [Backup]? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let snapshots = plist["Snapshots"] as? [[String: Any]] else { return nil }
        var seen = Set<String>()
        return snapshots.compactMap { snapshot -> Backup? in
            guard let name = snapshot["SnapshotName"] as? String, name.hasSuffix(".backup") || name.hasPrefix(snapshotPrefix),
                  let stamp = stamp(inName: name), let date = date(fromStamp: stamp), seen.insert(stamp).inserted else { return nil }
            return Backup(stamp: stamp, date: date)
        }.sorted { $0.date < $1.date }
    }

    /// Whether a backup is running now (`tmutil status`, `Running = 1`); nil when that could not be read. Nothing is deleted while one
    /// runs, or while that is unknown.
    public static func isBackingUp(runner: any CommandRunning = ProcessCommandRunner(defaultTimeout: 15)) -> Bool? {
        guard let result = try? runner.run(tool, ["status"]), result.exitCode == 0 else { return nil }
        return parseRunning(String(decoding: result.stdout, as: UTF8.self))
    }

    public static func parseRunning(_ status: String) -> Bool? {
        for line in status.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " ;\"\t")) }
            if parts.count == 2, parts[0] == "Running" { return parts[1] == "1" }
        }
        return nil
    }

    /// The disk's size and its free space, for the backup disk's row.
    public static func capacity(of mountPoint: String) -> (total: UInt64, free: UInt64)? {
        var info = statfs()
        guard statfs(mountPoint, &info) == 0 else { return nil }
        let block = UInt64(info.f_bsize)
        return (UInt64(info.f_blocks) * block, UInt64(info.f_bavail) * block)
    }
}
