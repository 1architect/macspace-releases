import XCTest
import MacSpaceSdk
@testable import MacSpaceApp

private actor FocusScanControl {
    private(set) var active = true
    private(set) var cancellations = 0
    private(set) var starts = 0
    private var revision = 0
    private var held = false
    private var waiters: [CheckedContinuation<Int, Never>] = []
    private var reports: [LoadProgressSink] = []
    var pending: Bool { !waiters.isEmpty }
    func arm() { held = true }
    func setActive(_ value: Bool) {
        active = value
        if !value && !waiters.isEmpty {
            cancellations += 1; held = false
            let pending = waiters; waiters = []; reports = []
            // A marker makes it observable if the host publishes a cancelled/cached reply as a fresh success.
            for waiter in pending { waiter.resume(returning: -1) }
        }
    }
    func read(_ progress: @escaping LoadProgressSink) async -> Int {
        guard active else { return -1 }
        guard held else { return revision }
        if waiters.isEmpty { starts += 1 }
        reports.append(progress); progress(0)
        return await withCheckedContinuation { waiters.append($0) }
    }
    func advance(_ value: Double) { for report in reports { report(value) } }
    func finish() {
        held = false; revision += 1
        for report in reports { report(1) }
        let pending = waiters; waiters = []; reports = []
        for waiter in pending { waiter.resume(returning: revision) }
    }
}

private struct FocusScanModule: MacSpaceModule {
    let control: FocusScanControl
    init() { control = FocusScanControl() }
    init(_ control: FocusScanControl) { self.control = control }
    func setActive(_ active: Bool) async { await control.setActive(active) }
    func tile(context: ModuleContext) async -> Tile { await tile(context: context, progress: { _ in }) }
    func tile(context: ModuleContext, progress: @escaping LoadProgressSink) async -> Tile {
        let value = await control.read(progress)
        return Tile(title: "Fixture", figure: String(value), status: "Ready")
    }
    func screen(context: ModuleContext) async -> Screen { await screen(context: context, progress: { _ in }) }
    func screen(context: ModuleContext, progress: @escaping LoadProgressSink) async -> Screen {
        let value = await control.read(progress)
        return Screen(title: String(value), widgets: [.list(.init(id: "folders", rows: [Row(id: "folder", title: "Folder", pageID: "folder")]))])
    }
    func page(id: String, context: ModuleContext, progress: @escaping LoadProgressSink) async -> Screen? {
        let value = await control.read(progress)
        return Screen(title: String(value), widgets: [])
    }
    func perform(_ request: ActionRequest, context: ModuleContext, progress: @escaping ProgressSink) async -> ActionResult {
        let value = await control.read { progress(.init(fraction: $0, message: "Working")) }
        return ActionResult(outcome: value >= 0 ? .succeeded : .failed, message: "", refresh: false)
    }
}

@MainActor
final class FocusScanLifetimeTests: XCTestCase {
    private final class Activity { var active = true }
    private func handle(_ directory: URL, control: FocusScanControl) async throws -> ModuleHandle {
        try Fixtures.writeBundle(Fixtures.manifest(), name: "Focus", into: directory)
        let descriptor = try XCTUnwrap(ModuleScanner.scan(directory: directory).modules.first)
        let handle = ModuleHandle(descriptor: descriptor, settings: SettingsStore(defaults: Fixtures.defaults()),
            permissions: FakePermissions(), loader: { _ in FocusScanModule(control) })
        await handle.activate()
        return handle
    }
    private func waitForPending(_ control: FocusScanControl) async throws {
        for _ in 0..<100 { if await control.pending { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("The controlled read never started")
    }

    func testAppSwitchCannotCancelOrCompleteAnInFlightRefresh() async throws {
        let directory = try Fixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let original = ModuleHandle.isAppActive
        let activity = Activity()
        ModuleHandle.isAppActive = { activity.active }; defer { ModuleHandle.isAppActive = original }
        let control = FocusScanControl(), handle = try await handle(directory, control: control)
        defer { handle.deactivate() }
        await control.arm()
        let scan = Task { await handle.refresh(reload: true) }
        try await waitForPending(control)
        await control.advance(0.29)
        for _ in 0..<100 where handle.loading?.reported != 0.29 { try await Task.sleep(for: .milliseconds(5)) }
        for _ in 0..<3 {
            activity.active = false; handle.appResignedActive()
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertTrue(handle.isRefreshing, "Switching apps must not turn a cancelled cached reply into completion")
            activity.active = true; handle.appBecameActive()
            try await Task.sleep(for: .milliseconds(20))
        }
        let cancelled = await control.cancellations, starts = await control.starts
        XCTAssertEqual(cancelled, 0)
        XCTAssertEqual(starts, 1, "Returning to the app must join the existing read, not restart it")
        XCTAssertEqual(handle.loading?.reported, 0.29)
        XCTAssertEqual(handle.screen?.title, "0", "Cached content stays until the real read finishes")
        await control.finish(); await scan.value
        XCTAssertEqual(handle.screen?.title, "1")
        XCTAssertFalse(handle.isRefreshing); XCTAssertNil(handle.loading)
    }

    func testClosingTheLastWindowRetiresCancelledRepliesAndReopeningReadsAgain() async throws {
        let directory = try Fixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let original = ModuleHandle.isAppActive
        ModuleHandle.isAppActive = { true }; defer { ModuleHandle.isAppActive = original }
        let control = FocusScanControl(), handle = try await handle(directory, control: control)
        defer { handle.deactivate() }
        await control.arm()
        let scan = Task { await handle.refresh(reload: true) }
        try await waitForPending(control)
        handle.setWatched(false, screenVisible: false)
        await scan.value
        XCTAssertEqual(handle.screen?.title, "0")
        XCTAssertEqual(handle.tile?.figure, "0", "A cancelled response must not replace the last completed presentation")
        await control.arm()
        handle.setWatched(true, screenVisible: true)
        try await waitForPending(control)
        await control.finish()
        for _ in 0..<100 where handle.screen?.title != "1" { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(handle.screen?.title, "1")
    }

    func testInFlightActionFinishesInBackgroundBeforeOptionalActivitySuspends() async throws {
        let directory = try Fixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let original = ModuleHandle.isAppActive
        let activity = Activity()
        ModuleHandle.isAppActive = { activity.active }; defer { ModuleHandle.isAppActive = original }
        let control = FocusScanControl(), handle = try await handle(directory, control: control)
        defer { handle.deactivate() }
        await control.arm()
        let action = Task { await handle.perform(Action(id: "work", title: "Work"), quiet: true) }
        try await waitForPending(control)
        activity.active = false; handle.appResignedActive()
        try await Task.sleep(for: .milliseconds(20))
        let cancelled = await control.cancellations
        XCTAssertEqual(cancelled, 0)
        await control.finish()
        let result = await action.value
        XCTAssertEqual(result?.outcome, .succeeded)
        for _ in 0..<100 { if await !control.active { break }; try await Task.sleep(for: .milliseconds(5)) }
        let active = await control.active
        XCTAssertFalse(active, "Optional inventory should suspend once the actual work is done")
    }

    func testLazyPageReadSurvivesAChangeOfForegroundApp() async throws {
        let directory = try Fixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let original = ModuleHandle.isAppActive
        let activity = Activity()
        ModuleHandle.isAppActive = { activity.active }; defer { ModuleHandle.isAppActive = original }
        let control = FocusScanControl(), handle = try await handle(directory, control: control)
        defer { handle.deactivate() }
        await control.arm(); handle.pushGroup("folder")
        try await waitForPending(control)
        activity.active = false; handle.appResignedActive()
        try await Task.sleep(for: .milliseconds(20))
        let cancelled = await control.cancellations
        XCTAssertEqual(cancelled, 0)
        XCTAssertNil(handle.pages["folder"])
        await control.finish()
        for _ in 0..<100 where handle.pages["folder"] == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(handle.pages["folder"]?.title, "1")
    }
}
