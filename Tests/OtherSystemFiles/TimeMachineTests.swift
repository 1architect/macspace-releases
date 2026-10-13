import XCTest
import MacSpacePlatform
import MacSpaceSdk
@testable import MacSpaceOtherSystemFiles
@testable import MacSpaceOtherSystemFilesPrivileged

final class TimeMachineTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!

    // MARK: Reading

    func testStampsAreDatesOrNothing() {
        XCTAssertNotNil(TimeMachine.date(fromStamp: "2026-10-13-025134"))
        for bad in ["2026-02-30-120000", "2026-13-01-120000", "2026-10-06-250000", "2026-10-06-1200", "../../etc", "2026-10-06-12000a", "２０２６-10-06-120000"] {
            XCTAssertNil(TimeMachine.date(fromStamp: bad), bad)
        }
        XCTAssertEqual(TimeMachine.stamp(inName: "com.apple.TimeMachine.2026-10-13-025134.local"), "2026-10-13-025134")
        XCTAssertEqual(TimeMachine.stamp(inName: "2026-10-01-120000.backup"), "2026-10-01-120000")
        XCTAssertNil(TimeMachine.stamp(inName: "com.apple.os.update-810C7D51A2A937EEA6F4A05056790B457C70B7E66998ACC90A8D43A9B034564D"))
    }

    /// As `tmutil listlocalsnapshots /` printed it on 26B5101f, with an update snapshot macOS can also list.
    func testLocalSnapshotsAreTimeMachinesOnlyOldestFirst() {
        let output = """
            Snapshots for disk /:
            com.apple.TimeMachine.2026-10-13-025204.local
            com.apple.os.update-810C7D51A2A937EEA6F4A05056790B457C70B7E66998ACC90A8D43A9B034564D
            com.apple.TimeMachine.2026-10-13-025134.local
            com.apple.TimeMachine.not-a-date.local
            """
        let snapshots = TimeMachine.parseLocalSnapshots(output, timeZone: utc)
        XCTAssertEqual(snapshots.all.map(\.stamp), ["2026-10-13-025134", "2026-10-13-025204"])
    }

    /// Free leaves the newest and the snapshot of the last backup, which the next backup starts from; one sharing a kept stamp stays.
    func testFreeLeavesTheTwoTimeMachineNeeds() {
        func list(_ names: [String]) -> TimeMachine.LocalSnapshots {
            TimeMachine.parseLocalSnapshots(names.map { "com.apple.TimeMachine.\($0)" }.joined(separator: "\n"), timeZone: utc)
        }
        XCTAssertEqual(list(["2026-10-01-090000.backup", "2026-10-03-090000.backup", "2026-10-05-090000.local", "2026-10-06-110000.local"]).removable.map(\.stamp),
                       ["2026-10-01-090000", "2026-10-05-090000"])
        XCTAssertEqual(list(["2026-10-05-090000.local", "2026-10-06-110000.backup", "2026-10-06-110000.local"]).removable.map(\.stamp), ["2026-10-05-090000"])
        XCTAssertTrue(list(["2026-08-01-090000.backup"]).removable.isEmpty, "a single snapshot is never freed")
        XCTAssertTrue(TimeMachine.LocalSnapshots([]).removable.isEmpty)
    }

    func testDeletesOneStampAtATimeAndNeverTheWholeDisk() {
        let runner = FakeRunner()
        let failures = TimeMachine.deleteLocalSnapshots(["2026-10-13-025134", "/", "2026-10-13-025204"], runner: runner)
        XCTAssertEqual(runner.calls, [["deletelocalsnapshots", "2026-10-13-025134"], ["deletelocalsnapshots", "2026-10-13-025204"]])
        XCTAssertTrue(failures.isEmpty)
    }

    /// `tmutil destinationinfo`, in the form its man page documents.
    func testBackupDisksAreRead() {
        let output = """
            ====================================================
            Name          : Backups
            Kind          : Local
            Mount Point   : /Volumes/Backups
            ID            : 6A4B1D2E-0000-4000-8000-000000000001
            ====================================================
            >   Name          : NAS
            Kind          : Network
            URL           : smb://nas.local/TimeMachine
            ID            : 6A4B1D2E-0000-4000-8000-000000000002
            """
        let disks = TimeMachine.parseDestinations(output)
        XCTAssertEqual(disks, [TimeMachine.Destination(id: "6A4B1D2E-0000-4000-8000-000000000001", name: "Backups", kind: "Local", mountPoint: "/Volumes/Backups"),
                               TimeMachine.Destination(id: "6A4B1D2E-0000-4000-8000-000000000002", name: "NAS", kind: "Network", mountPoint: nil)])
    }

    /// An APFS backup disk lists each backup as a snapshot of itself.
    func testBackupsAreTheDisksTimeMachineSnapshots() throws {
        let plist: [String: Any] = ["Snapshots": [
            ["SnapshotName": "com.apple.TimeMachine.2026-10-02-120000.backup", "Purgeable": false],
            ["SnapshotName": "com.apple.TimeMachine.2026-10-01-120000.backup", "Purgeable": false],
            ["SnapshotName": "something-else", "Purgeable": true],
        ]]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        XCTAssertEqual(TimeMachine.parseSnapshotList(data)?.map(\.stamp), ["2026-10-01-120000", "2026-10-02-120000"])
    }

    func testABackupThatRunsIsSeen() {
        XCTAssertEqual(TimeMachine.parseRunning("Backup session status:\n{\n    ClientID = \"com.apple.backupd\";\n    Percent = \"-1\";\n    Running = 0;\n}"), false)
        XCTAssertEqual(TimeMachine.parseRunning("{\n    BackupPhase = Copying;\n    Running = 1;\n}"), true)
        XCTAssertNil(TimeMachine.parseRunning(""))
    }

    // MARK: Deleting backups (helper)

    private let disk = TimeMachine.Destination(id: "A", name: "Backups", kind: "Local", mountPoint: "/Volumes/Backups")

    private func backups(_ stamps: [String]) -> [TimeMachine.Backup] {
        stamps.map { TimeMachine.Backup(stamp: $0, date: TimeMachine.date(fromStamp: $0)!) }
    }

    func testTheHelperDeletesOnlyOldBackupsOfAConnectedBackupDisk() {
        let runner = FakeRunner()
        var listed = backups(["2026-10-01-120000", "2026-10-02-120000", "2026-10-03-120000"])
        runner.onDelete = { stamps in listed.removeAll { stamps.contains($0.stamp) } }
        let deleter = BackupDeleter(runner: runner, destinations: { [self.disk] }, backups: { _ in listed }, isBackingUp: { false }, free: { _ in 1 })
        let result = deleter.execute(mountPoint: "/Volumes/Backups", stamps: ["2026-10-01-120000", "2026-10-03-120000", "2026-09-01-120000", "../x"])
        XCTAssertEqual(runner.calls, [["delete", "-d", "/Volumes/Backups", "-t", "2026-10-01-120000"]])
        XCTAssertEqual(result.deleted, ["2026-10-01-120000"])
        XCTAssertEqual(result.kept["2026-10-03-120000"], "The latest backup is kept.")
        XCTAssertEqual(result.kept["2026-09-01-120000"], "Not on the disk.")
        XCTAssertEqual(result.kept["../x"], "Not a backup's date.")
    }

    func testTheHelperRefusesAnotherDiskARunningBackupOrAnUnknownState() {
        let runner = FakeRunner()
        let listed = backups(["2026-10-01-120000", "2026-10-02-120000"])
        func deleter(running: Bool?) -> BackupDeleter {
            BackupDeleter(runner: runner, destinations: { [self.disk] }, backups: { _ in listed }, isBackingUp: { running }, free: { _ in 1 })
        }
        XCTAssertFalse(deleter(running: false).execute(mountPoint: "/Volumes/Other", stamps: ["2026-10-01-120000"]).executed)
        XCTAssertFalse(deleter(running: true).execute(mountPoint: "/Volumes/Backups", stamps: ["2026-10-01-120000"]).executed)
        XCTAssertFalse(deleter(running: nil).execute(mountPoint: "/Volumes/Backups", stamps: ["2026-10-01-120000"]).executed)
        XCTAssertTrue(runner.calls.isEmpty, "tmutil never ran")
        XCTAssertEqual(TimeMachinePrivilegedOperations().operations, ["timemachine.backups.delete"])
        XCTAssertTrue(TimeMachinePrivilegedOperations().readOnlyOperations.isEmpty, "only an administrator may delete backups")
    }

    // MARK: Page

    private func snapshot(snapshots: [String], estimate: UInt64, disks: [TimeMachineState.BackupDisk] = [], backingUp: Bool? = false) -> PurgeableSnapshot {
        var snap = PurgeableSnapshot(services: [CacheDeleteService.timeMachineSnapshots: estimate], takenAt: Date())
        snap.timeMachine = TimeMachineState(snapshots: TimeMachine.parseLocalSnapshots(snapshots.map { "com.apple.TimeMachine.\($0)" }.joined(separator: "\n")),
                                            disks: disks, backingUp: backingUp)
        return snap
    }

    func testOlderSnapshotsAreFreedUnderFreeNow() throws {
        let snap = snapshot(snapshots: ["2026-10-13-010000.local", "2026-10-13-020000.local", "2026-10-13-030000.local"], estimate: 1_690_000_000)
        guard case let .section(free)? = OtherSystemFilesScreenBuilder.freeNow(snap), case let .list(list) = free.widgets[0] else { return XCTFail() }
        let row = try XCTUnwrap(list.rows.first { $0.id == CacheDeleteService.timeMachineSnapshots })
        XCTAssertEqual(row.title, "Time Machine snapshots")
        XCTAssertEqual(row.subtitle, "3 snapshots")
        XCTAssertEqual(row.badge?.text, "Cannot be undone")
        XCTAssertEqual(row.actions.map(\.id), ["freeSnapshots"])
        XCTAssertNotNil(row.actions.first?.confirmation)
        XCTAssertNil(OtherSystemFilesScreenBuilder.keptSection(snap), "listed once")
        let block = try XCTUnwrap(OtherSystemFilesScreenBuilder.blocksWithItems(snap).first { $0.id == CacheDeleteService.timeMachineSnapshots })
        XCTAssertEqual(block.items.map(\.id), [CacheDeleteService.timeMachineSnapshots], "the chart's block opens the same row")
    }

    func testSnapshotsTimeMachineStillNeedsAreShownWithoutAButton() throws {
        let snap = snapshot(snapshots: ["2026-10-13-030000.backup"], estimate: 0)
        XCTAssertNil(OtherSystemFilesScreenBuilder.freeNow(snap))
        guard case let .section(kept)? = OtherSystemFilesScreenBuilder.keptSection(snap), case let .list(list) = kept.widgets[0] else { return XCTFail() }
        XCTAssertEqual(list.rows.map(\.id), [CacheDeleteService.timeMachineSnapshots], "shown even while macOS's figure lags at 0")
        XCTAssertTrue(list.rows[0].actions.isEmpty)
    }

    func testNoButtonWhileABackupRuns() throws {
        let snap = snapshot(snapshots: ["2026-10-13-010000.local", "2026-10-13-020000.local", "2026-10-13-030000.local"], estimate: 1_000_000_000, backingUp: true)
        let row = try XCTUnwrap(OtherSystemFilesScreenBuilder.snapshotsRow(snap)?.row)
        XCTAssertTrue(row.actions.isEmpty)
        XCTAssertTrue(row.badges.contains { $0.text == "Backing up now" })
    }

    func testABackupDiskListsItsBackupsAndLetsTheOldOnesBeChosen() throws {
        let connected = TimeMachineState.BackupDisk(destination: disk, backups: backups(["2026-10-01-120000", "2026-10-02-120000", "2026-10-03-120000"]),
                                                    totalBytes: 2_000_000_000_000, freeBytes: 500_000_000_000)
        let away = TimeMachineState.BackupDisk(destination: TimeMachine.Destination(id: "B", name: "Old disk", kind: "Local", mountPoint: nil))
        let snap = snapshot(snapshots: [], estimate: 0, disks: [away, connected])
        guard case let .section(section)? = OtherSystemFilesScreenBuilder.backupDisksSection(snap), case let .list(list) = section.widgets[0] else { return XCTFail() }
        XCTAssertEqual(list.rows.map(\.title), ["Backups", "Old disk"], "largest first; one not connected has no size")
        let group = list.rows[0]
        XCTAssertEqual(group.subtitle, "3 backups")
        XCTAssertEqual(group.children.map(\.id), ["backup:2026-10-03-120000", "backup:2026-10-02-120000", "backup:2026-10-01-120000"], "newest first")
        XCTAssertEqual(group.children.first?.badge?.text, "Latest")
        let selection = try XCTUnwrap(group.selection)
        XCTAssertEqual(Set(selection.choices.keys), ["backup:2026-10-01-120000", "backup:2026-10-02-120000"], "never the latest")
        XCTAssertTrue(selection.checked.isEmpty, "nothing is chosen for the user")
        XCTAssertEqual(selection.action.parameters["mountPoint"], "/Volumes/Backups")
        XCTAssertEqual(selection.action.requires, [.privilegedHelper])
        XCTAssertEqual(list.rows[1].badge?.text, "Not connected")
        XCTAssertFalse(OtherSystemFilesScreenBuilder.blocksWithItems(snap).contains { $0.id.hasPrefix("backupdisk:") }, "a backup disk is not this Mac's space")
    }
}

/// The symbols for crash reports are the largest part of the purgeable app files on the development Mac (1.55 of 2.74 GB, and Free up
/// to removed them): the row says so, as nothing else names them.
final class SymbolsInPurgeableFilesTests: XCTestCase {
    private func snapshot(estimate: UInt64, symbols: UInt64?) -> PurgeableSnapshot {
        var snap = PurgeableSnapshot(services: [CacheDeleteService.fsPurgeableData: estimate], takenAt: Date())
        snap.symbolsBytes = symbols
        return snap
    }

    private func detail(_ snap: PurgeableSnapshot) -> String? {
        guard case let .section(free)? = OtherSystemFilesScreenBuilder.freeNow(snap), case let .list(list) = free.widgets[0] else { return nil }
        return list.rows.first { $0.id == CacheDeleteService.fsPurgeableData }?.detail
    }

    func testThePurgeableFilesRowNamesTheSymbols() {
        XCTAssertTrue(detail(snapshot(estimate: 2_740_000_000, symbols: 1_546_256_384))?.contains("symbols for crash reports") == true)
        XCTAssertFalse(detail(snapshot(estimate: 2_740_000_000, symbols: 10_000_000))?.contains("symbols") == true, "too small to say")
        XCTAssertFalse(detail(snapshot(estimate: 2_740_000_000, symbols: nil))?.contains("symbols") == true, "unknown without the helper")
        XCTAssertNil(OtherSystemFilesScreenBuilder.symbolsLine(snapshot(estimate: 100_000_000, symbols: 1_546_256_384)),
                     "never more than macOS's own figure")
    }
}

final class FakeRunner: CommandRunning, @unchecked Sendable {
    let lock = NSLock()
    var calls: [[String]] = []
    var onDelete: ([String]) -> Void = { _ in }
    func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        lock.lock(); defer { lock.unlock() }
        XCTAssertEqual(executable, "/usr/bin/tmutil")
        calls.append(arguments)
        if arguments.first == "delete" { onDelete(stride(from: 4, to: arguments.count, by: 2).map { arguments[$0] }) }
        return CommandResult(stdout: Data(), stderr: Data(), exitCode: 0)
    }
}
