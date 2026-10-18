import XCTest
import MacSpacePlatform
import MacSpaceSdk
@testable import MacSpaceSystemData
@testable import MacSpaceSystemDataPrivileged

final class UnifiedLogTests: XCTestCase {
    final class FakeLog: CommandRunning, @unchecked Sendable {
        let lock = NSLock()
        var calls: [[String]] = []
        var failing: Set<String> = []
        /// What erasing leaves in the folders.
        var onErase: () -> Void = {}
        func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
            lock.lock(); defer { lock.unlock() }
            XCTAssertEqual(executable, "/usr/bin/log", "only Apple's own command runs")
            calls.append(arguments)
            if failing.contains(arguments.last ?? "") {
                return CommandResult(stdout: Data(), stderr: Data("log: Must be run as root".utf8), exitCode: 64)
            }
            if arguments == ["erase", "--all"] { onErase() }
            return CommandResult(stdout: Data("All log messages deleted".utf8), stderr: Data(), exitCode: 0)
        }
    }

    private func folders() throws -> (store: URL, strings: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("log-\(UUID().uuidString)")
        let store = root.appendingPathComponent("diagnostics"), strings = root.appendingPathComponent("uuidtext")
        try FileManager.default.createDirectory(at: store.appendingPathComponent("Persist"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: strings.appendingPathComponent("AB"), withIntermediateDirectories: true)
        try Data(count: 4_000_000).write(to: store.appendingPathComponent("Persist/0000000000000001.tracev3"))
        try Data(count: 2_000_000).write(to: strings.appendingPathComponent("AB/CDEF"))
        return (store, strings)
    }

    func testErasesEveryStoreThenPrunesTheFormatStrings() throws {
        let (store, strings) = try folders()
        defer { try? FileManager.default.removeItem(at: store.deletingLastPathComponent()) }
        let log = FakeLog()
        log.onErase = { try? FileManager.default.removeItem(at: store.appendingPathComponent("Persist/0000000000000001.tracev3")) }
        let result = UnifiedLogCleaner(paths: [store.path, strings.path], runner: log).execute()
        XCTAssertEqual(log.calls, [["erase", "--all"], ["erase", "--uuidtext"]])
        XCTAssertTrue(result.executed)
        XCTAssertTrue(result.prunedFormatStrings)
        XCTAssertNil(result.error)
        XCTAssertGreaterThan(result.bytesBefore ?? 0, result.bytesAfter ?? .max)
    }

    func testNothingElseRunsWhenTheEraseFails() throws {
        let (store, strings) = try folders()
        defer { try? FileManager.default.removeItem(at: store.deletingLastPathComponent()) }
        let log = FakeLog()
        log.failing = ["--all"]
        let result = UnifiedLogCleaner(paths: [store.path, strings.path], runner: log).execute()
        XCTAssertEqual(log.calls, [["erase", "--all"]], "no prune without the erase")
        XCTAssertFalse(result.executed)
        XCTAssertTrue(result.error?.contains("Must be run as root") == true, "the command's own words are kept")
    }

    func testAFailedPruneStillCountsTheErase() throws {
        let (store, strings) = try folders()
        defer { try? FileManager.default.removeItem(at: store.deletingLastPathComponent()) }
        let log = FakeLog()
        log.failing = ["--uuidtext"]
        let result = UnifiedLogCleaner(paths: [store.path, strings.path], runner: log).execute()
        XCTAssertTrue(result.executed)
        XCTAssertFalse(result.prunedFormatStrings)
        XCTAssertNotNil(result.error)
    }

    func testTheHelperOffersTheEraseWithoutArguments() {
        XCTAssertTrue(SystemDataPrivilegedOperations().operations.contains("systemdata.unified-log.erase"))
        XCTAssertFalse(SystemDataPrivilegedOperations().readOnlyOperations.contains("systemdata.unified-log.erase"))
    }

    // MARK: Page

    private func snapshot(_ items: [SystemDataItem]) -> SystemDataSnapshot {
        SystemDataSnapshot(report: SystemDataReport(schemaVersion: 1, generatedAt: Date(), items: items, measuredBytes: 0, unreadable: []),
                           purgeableAssetsBytes: nil, reports: CleanupPlan(olderThanDays: 7, cutoff: .distantPast, candidates: [], totalBytes: 0, unreadableDirectories: []),
                           takenAt: Date())
    }

    private var logItem: SystemDataItem {
        SystemDataItem(id: "logs:unified", title: "Unified system log", kind: .logs, paths: ["/private/var/db/diagnostics", "/private/var/db/uuidtext"],
                       bytes: 2_900_000_000, readable: true, owners: [], inUse: false,
                       cleanup: SystemDataCleanup(kind: .managedByMacOS, description: "d", command: nil), notes: [])
    }

    /// Mole deletes the log's older files, and macOS never frees it: the page offers it under Free now, with its own button that needs
    /// the helper and cannot be undone, and Clean leaves it out.
    func testTheSystemLogIsFreedWithItsOwnButton() throws {
        let snap = snapshot([logItem])
        guard case let .section(free)? = SystemDataScreenBuilder.freeNow(snap), case let .list(list) = free.widgets[0] else { return XCTFail() }
        let row = try XCTUnwrap(list.rows.first { $0.id == "system-log" })
        XCTAssertEqual(row.badge?.text, "Cannot be undone")
        XCTAssertEqual(row.actions.map(\.id), ["eraseUnifiedLog"])
        XCTAssertEqual(row.actions.first?.title, "Free")
        XCTAssertEqual(row.actions.first?.requires, [.privilegedHelper])
        XCTAssertNotNil(row.actions.first?.confirmation)
        XCTAssertEqual(row.paths, logItem.paths)
        XCTAssertEqual(SystemDataScreenBuilder.cleanBytes(snap), 0, "Clean never erases the log")
        XCTAssertEqual(SystemDataScreenBuilder.freeableBytes(snap), 2_900_000_000, "the tile counts it, as the version history")
        XCTAssertFalse(SystemDataScreenBuilder.leftAlone(snap).contains { $0.id == "logs:unified" }, "listed once, where it is freed")
    }

    func testASmallLogIsNotWorthARow() {
        var item = logItem
        item.bytes = 10_000_000
        XCTAssertNil(SystemDataScreenBuilder.unifiedLogRow(snapshot([item])))
    }

    // MARK: Code-signing copies

    private func copyItem(_ id: String, bytes: UInt64, unshared: UInt64) -> SystemDataItem {
        var item = SystemDataItem(id: "clone:\(id)", title: "SketchUp", kind: .codeSignClone, paths: ["/var/folders/x/X/\(id).code_sign_clone"],
                                  bytes: bytes, readable: true, owners: [id], inUse: false,
                                  cleanup: SystemDataCleanup(kind: .deleteWhenNotRunning, description: "d", command: nil), notes: [])
        item.expectedReclaimBytes = unshared
        return item
    }

    /// A copy is listed by what it does not share with its app, under the app's name, and only when that is worth it.
    func testOldAppCopiesAreListedByWhatTheyFree() {
        let entries = CachesPage.entries(snapshot([copyItem("com.sketchup.SketchUp.2026", bytes: 2_420_000_000, unshared: 900_000_000),
                                                   copyItem("com.sketchup.LayOut.2026", bytes: 970_000_000, unshared: 10_000_000)]))
        XCTAssertEqual(entries.map(\.id), ["clone:com.sketchup.SketchUp.2026"], "a copy sharing almost everything is not offered")
        XCTAssertEqual(entries.first?.bytes, 900_000_000, "sized by its own blocks, not its 2.42 GB")
        XCTAssertEqual(entries.first?.title, "SketchUp")
        XCTAssertEqual(entries.first?.source, .appCopy)
    }

    func testAProgramRunningFromInsideAFolderIsSeen() {
        let processes = [RunningProcess(pid: 1, name: "SketchUp", executablePath: "/private/tmp/x.code_sign_clone/a/SketchUp.app/Contents/MacOS/SketchUp"),
                         RunningProcess(pid: 2, name: "zsh", executablePath: "/bin/zsh")]
        XCTAssertEqual(ProcessCheck.runningFromInside(["/private/tmp/x.code_sign_clone"], processes: processes), "SketchUp")
        XCTAssertNil(ProcessCheck.runningFromInside(["/private/tmp/x.code_sign"], processes: processes), "a name that only starts the same is not inside")
    }
}
