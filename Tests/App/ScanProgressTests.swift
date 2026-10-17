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
    init() { control = ScanControl() }
    init(control: ScanControl) { self.control = control }
    func tile(context: ModuleContext) async -> Tile { Tile(title: "test", status: "ready") }
    func screen(context: ModuleContext) async -> Screen { Screen(title: "Test", widgets: []) }
    func screen(context: ModuleContext, progress: @escaping LoadProgressSink) async -> Screen {
        await control.scan(progress)
        return await screen(context: context)
    }
    func perform(_ request: ActionRequest, context: ModuleContext, progress: @escaping ProgressSink) async -> ActionResult { .succeeded("") }
}

@MainActor
final class ScanProgressTests: XCTestCase {
    private func handle(_ directory: URL, control: ScanControl) async throws -> ModuleHandle {
        try Fixtures.writeBundle(Fixtures.manifest(), name: "Test", into: directory)
        let descriptor = try XCTUnwrap(ModuleScanner.scan(directory: directory).modules.first)
        let module = ScanningModule(control: control)
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
            XCTAssertTrue(handle.isBusy)
            XCTAssertTrue(TileInfo(handle).loading, "the home widget pulses during either scan")
            await control.advance(0.4)
            for _ in 0..<100 where handle.loading?.reported != 0.4 { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertEqual(handle.loading?.reported, 0.4)
            XCTAssertEqual(TileInfo(handle).status, TileInfo.loadingStatus + " 40%")
            XCTAssertEqual(handle.loading?.fraction(at: Date()), 0.4, "the orange button uses actual scan progress")
            await control.advance(0.2)
            try await Task.sleep(for: .milliseconds(10))
            XCTAssertEqual(handle.loading?.reported, 0.4, "progress never moves backwards")
            await control.finish()
            await task.value
            XCTAssertFalse(handle.isRefreshing)
            XCTAssertFalse(handle.isBusy)
            XCTAssertNil(handle.loading)
            XCTAssertFalse(TileInfo(handle).loading)
            XCTAssertEqual(TileInfo(handle).status, "ready")
            // A queued/late callback must not bring loading back after the read has completed.
            await control.advance(0.8)
            try await Task.sleep(for: .milliseconds(10))
            XCTAssertFalse(handle.isRefreshing)
        }
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
}
