import XCTest
import MacSpaceSdk
@testable import MacSpaceApp

/// Holds a real progress-reporting read open so the UI's state can be checked before it completes.
private actor ScanControl {
    private var armed = false
    private var reports: LoadProgressSink?
    private var resume: CheckedContinuation<Void, Never>?
    func arm() { armed = true }
    var started: Bool { resume != nil }
    func scan(_ progress: @escaping LoadProgressSink) async {
        guard armed else { return }
        armed = false
        reports = progress
        progress(0)
        await withCheckedContinuation { resume = $0 }
    }
    func advance(_ fraction: Double) { reports?(fraction) }
    func finish() { reports?(1); resume?.resume(); resume = nil }
}

private struct ScanningModule: MacSpaceModule {
    let control: ScanControl
    let refreshAfter: TimeInterval?
    init() { control = ScanControl(); refreshAfter = nil }
    init(control: ScanControl, refreshAfter: TimeInterval? = nil) { self.control = control; self.refreshAfter = refreshAfter }
    func tile(context: ModuleContext) async -> Tile { Tile(title: "test", status: "ready", refreshAfter: refreshAfter) }
    func screen(context: ModuleContext) async -> Screen { Screen(title: "Test", widgets: []) }
    func screen(context: ModuleContext, progress: @escaping LoadProgressSink) async -> Screen {
        await control.scan(progress)
        return await screen(context: context)
    }
    func perform(_ request: ActionRequest, context: ModuleContext, progress: @escaping ProgressSink) async -> ActionResult { .succeeded("Done") }
}

@MainActor
final class ScanProgressTests: XCTestCase {
    private func handle(_ directory: URL, control: ScanControl, refreshAfter: TimeInterval? = nil) async throws -> ModuleHandle {
        try Fixtures.writeBundle(Fixtures.manifest(), name: "Test", into: directory)
        let descriptor = try XCTUnwrap(ModuleScanner.scan(directory: directory).modules.first)
        let module = ScanningModule(control: control, refreshAfter: refreshAfter)
        let handle = ModuleHandle(descriptor: descriptor, settings: SettingsStore(defaults: Fixtures.defaults()), permissions: FakePermissions(), loader: { _ in module })
        await handle.activate()
        return handle
    }

    func testFullAndQuietScansBothPublishProgressAndClearLoadingWhenDone() async throws {
        for quiet in [false, true] {
            let directory = try Fixtures.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let control = ScanControl()
            let handle = try await handle(directory, control: control)
            await control.arm()
            let task = Task { await handle.refresh(quiet: quiet) }
            for _ in 0..<100 {
                if await control.started, handle.isRefreshing { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertTrue(handle.isRefreshing)
            XCTAssertFalse(handle.isBusy, "all scans retain an interactive existing page")
            XCTAssertFalse(handle.isReloading, "manual refresh also keeps existing details")
            XCTAssertTrue(TileInfo(handle).loading, "the home widget pulses during either scan")
            await control.advance(0.4)
            for _ in 0..<100 where handle.loading?.reported != 0.4 { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertEqual(handle.loading?.reported, 0.4)
            XCTAssertEqual(TileInfo(handle).status, TileInfo.loadingStatus + " 40%", "even a short scan reports loading and real progress immediately")
            XCTAssertEqual(handle.loading?.fraction(at: Date()), 0.4, "the orange button uses actual scan progress")
            await control.advance(0.2)
            try await Task.sleep(for: .milliseconds(10))
            XCTAssertEqual(handle.loading?.reported, 0.4, "progress never moves backwards")
            await control.finish()
            await task.value
            XCTAssertFalse(handle.isRefreshing)
            XCTAssertFalse(handle.isBusy)
            XCTAssertFalse(handle.isReloading)
            XCTAssertNil(handle.loading)
            XCTAssertFalse(TileInfo(handle).loading)
            XCTAssertEqual(TileInfo(handle).status, "ready")
            // A queued/late callback must not bring loading back after the read has completed.
            await control.advance(0.8)
            try await Task.sleep(for: .milliseconds(10))
            XCTAssertFalse(handle.isRefreshing)
        }
    }

    func testPageActionVerificationLeavesTheExistingPageInteractiveBehindCompletion() async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let control = ScanControl()
        let handle = try await handle(directory, control: control)
        defer { handle.deactivate() }
        await control.arm()
        let task = Task { await handle.perform(Action(id: "clean", title: "Free")) }
        for _ in 0..<100 {
            if await control.started, handle.isRefreshing { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(handle.isShowingCompletion)
        XCTAssertTrue(handle.isCleaning, "graphs keep pulsing until verification finishes")
        XCTAssertTrue(handle.isRefreshing)
        XCTAssertFalse(handle.isBusy, "the action has finished; returning from All done must expose a live page")
        XCTAssertFalse(handle.isReloading)
        handle.dismissCompletion()
        XCTAssertFalse(handle.isShowingCompletion)
        XCTAssertNotNil(handle.screen)
        await control.finish()
        _ = await task.value
        XCTAssertFalse(handle.isCleaning)
    }

    func testProgressFromHiddenScansDoesNotRestoreVisibleLoading() async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let control = ScanControl()
        let handle = try await handle(directory, control: control)
        handle.setWatched(false)
        await control.arm()
        let task = Task { await handle.refresh(quiet: true) }
        for _ in 0..<100 {
            if await control.started { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        await control.advance(0.5)
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertFalse(handle.isRefreshing)
        XCTAssertNil(handle.loading)
        await control.finish()
        await task.value
    }

    func testAutomaticInvalidationKeepsThePageVisibleAndAnExplicitRefreshSupersedesOldWork() async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let control = ScanControl()
        let handle = try await handle(directory, control: control)
        defer { handle.deactivate() }
        await control.arm()
        let old = Task { await handle.refresh(reload: true, quiet: true) }
        for _ in 0..<100 {
            if await control.started, handle.isRefreshing { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(handle.isRefreshing)
        XCTAssertFalse(handle.isReloading, "automatic invalidation reports progress without folding the page")
        XCTAssertFalse(handle.isBusy)
        await handle.refresh(reload: true)
        XCTAssertFalse(handle.isRefreshing, "an obsolete scan cannot keep a newer completed read loading")
        XCTAssertFalse(handle.isReloading)
        XCTAssertNil(handle.loading)
        await control.advance(0.9)
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertFalse(handle.isRefreshing)
        await control.finish()
        await old.value
        XCTAssertFalse(handle.isRefreshing)
    }

    func testPendingAutomaticTimerCannotInterruptAnExplicitReload() async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let control = ScanControl()
        let handle = try await handle(directory, control: control, refreshAfter: 2)
        defer { handle.deactivate() }
        await control.arm()
        let manual = Task { await handle.refresh(reload: true) }
        for _ in 0..<100 {
            if await control.started { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        try await Task.sleep(for: .milliseconds(2200))
        XCTAssertTrue(handle.isRefreshing, "the pending two-second timer must not interrupt the manual scan")
        XCTAssertFalse(handle.isReloading)
        XCTAssertFalse(handle.isBusy)
        XCTAssertTrue(TileInfo(handle).status.hasPrefix(TileInfo.loadingStatus), "loading has no three-second delay")
        await control.finish()
        await manual.value
        XCTAssertFalse(handle.isReloading)
        XCTAssertFalse(handle.isRefreshing)
    }
}
