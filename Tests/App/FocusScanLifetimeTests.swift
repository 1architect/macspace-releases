import XCTest
import MacSpaceSdk
@testable import MacSpaceApp

private actor FocusScanControl {
    private(set) var active = true
    private(set) var cancellations = 0
    private(set) var starts = 0
    private var revision = 0
    private var held = false
    private var initialProgress = true
    private var waiters: [CheckedContinuation<Int, Never>] = []
    private var reports: [LoadProgressSink] = []
    var pending: Bool { !waiters.isEmpty }
    func arm(initialProgress: Bool = true) { held = true; self.initialProgress = initialProgress }
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
        reports.append(progress); if initialProgress { progress(0) }
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
        return Screen(title: String(value), primary: Action(id: "work", title: "Work"), widgets: [.list(.init(id: "folders", rows: [Row(id: "folder", title: "Folder", pageID: "folder")]))])
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
        let handle = ModuleHandle(confirm: { _ in true }, descriptor: descriptor, settings: SettingsStore(defaults: Fixtures.defaults()),
            permissions: FakePermissions(), loader: { _ in FocusScanModule(control) })
        await handle.activate()
        return handle
    }
    private func waitForPending(_ control: FocusScanControl) async throws {
        for _ in 0..<100 { if await control.pending { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("The controlled read never started")
    }

    func testClosingToTheMenuBarAndReopeningRetainsTheSameScanAndProgress() async throws {
        let directory = try Fixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let original = ModuleHandle.isAppActive, activity = Activity()
        ModuleHandle.isAppActive = { activity.active }; defer { ModuleHandle.isAppActive = original }
        let control = FocusScanControl(), handle = try await handle(directory, control: control)
        defer { handle.deactivate(); Task { await control.finish() } }
        await control.arm()
        let scan = Task { await handle.refresh(quiet: true) }
        try await waitForPending(control)
        await control.advance(0.42)
        for _ in 0..<100 where handle.loading?.reported != 0.42 { try await Task.sleep(for: .milliseconds(5)) }
        let started = handle.loading?.started
        activity.active = false
        handle.setWatched(false, screenVisible: false)
        handle.appResignedActive()
        try await Task.sleep(for: .milliseconds(40))
        var cancellations = await control.cancellations
        XCTAssertEqual(cancellations, 0)
        XCTAssertEqual(handle.loading?.reported, 0.42)
        activity.active = true
        handle.setWatched(true, screenVisible: true)
        handle.appBecameActive()
        try await Task.sleep(for: .milliseconds(30))
        cancellations = await control.cancellations
        XCTAssertEqual(cancellations, 0)
        XCTAssertEqual(handle.loading?.reported, 0.42)
        XCTAssertEqual(handle.loading?.started, started)
        await control.finish(); await scan.value
    }

    func testClosedWindowReadFinishesIntoCacheAndSuspendsWithoutWaitingForTheDeadline() async throws {
        let directory = try Fixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let original = ModuleHandle.isAppActive
        ModuleHandle.isAppActive = { true }; defer { ModuleHandle.isAppActive = original }
        let control = FocusScanControl(), handle = try await handle(directory, control: control)
        defer { handle.deactivate(); Task { await control.finish() } }
        await control.arm()
        let scan = Task { await handle.refresh(quiet: true) }
        try await waitForPending(control)
        handle.setWatched(false, screenVisible: false)
        try await Task.sleep(for: .milliseconds(30))
        await control.finish(); await scan.value
        for _ in 0..<100 { if await !control.active { break }; try await Task.sleep(for: .milliseconds(5)) }
        let cancellations = await control.cancellations, active = await control.active
        XCTAssertEqual(cancellations, 0)
        XCTAssertEqual(handle.screen?.title, "1")
        XCTAssertFalse(active, "Finished hidden work must release its backend promptly")
        XCTAssertNil(handle.loading)
    }

    func testSwitchingToAnotherModuleKeepsTheFirstDiskScanUntilTheLastCanvasCloses() async throws {
        let directory = try Fixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let original = ModuleHandle.isAppActive
        ModuleHandle.isAppActive = { true }; defer { ModuleHandle.isAppActive = original }
        let control = FocusScanControl(), canvas = UUID()
        try Fixtures.writeBundle(Fixtures.manifest(id: "com.macspace.disk-map"), name: "Disk", into: directory)
        try Fixtures.writeBundle(Fixtures.manifest(id: "com.test.other"), name: "Other", into: directory)
        let host = ModuleHost(modulesDirectory: directory, settings: SettingsStore(defaults: Fixtures.defaults()), permissions: FakePermissions(), privileged: nil,
                              loader: { descriptor -> any MacSpaceModule in
                                  if descriptor.id == "com.macspace.disk-map" { return FocusScanModule(control) }
                                  return FakeModule()
                              })
        defer { host.handles.forEach { $0.deactivate() }; host.scheduler.stopAll(); Task { await control.finish() } }
        host.setVisibleDestination(.storage, for: canvas)
        await control.arm()
        let startup = Task { await host.reload() }
        try await waitForPending(control)
        let handle = try XCTUnwrap(host.handle(for: "com.macspace.disk-map"))
        handle.hiddenReadGrace = .zero
        XCTAssertNil(handle.screen)
        await control.advance(0.22)
        for _ in 0..<100 where handle.loading?.reported != 0.22 { try await Task.sleep(for: .milliseconds(5)) }
        let started = handle.loading?.started
        host.setVisibleDestination(.home, for: canvas)
        host.setVisibleDestination(.module("com.test.other"), for: canvas)
        try await Task.sleep(for: .milliseconds(50))
        let coveredCancellations = await control.cancellations
        XCTAssertEqual(coveredCancellations, 0, "Covering Disk with another module must not cancel its active scan")
        XCTAssertFalse(handle.isWatched, "The covered module must not start periodic reads")
        XCTAssertTrue(handle.isRefreshing)
        XCTAssertEqual(handle.loading?.reported, 0.22)
        XCTAssertEqual(handle.loading?.started, started)
        host.setVisibleDestination(.home, for: canvas)
        host.setVisibleDestination(.storage, for: canvas)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(handle.loading?.reported, 0.22)
        XCTAssertEqual(handle.loading?.started, started)
        let starts = await control.starts
        XCTAssertEqual(starts, 1)
        host.setVisibleDestination(nil, for: canvas)
        await startup.value
        let finalCancellations = await control.cancellations
        XCTAssertEqual(finalCancellations, 1, "Closing the last canvas must still cancel optional work")
        XCTAssertNil(handle.screen, "A cancelled reply must not become a completed page")
        XCTAssertNil(handle.loading)
    }

    func testReturningToACachedPageDoesNotClearAnAlreadyRunningRefresh() async throws {
        let directory = try Fixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let control = FocusScanControl(), handle = try await handle(directory, control: control)
        defer { handle.deactivate(); Task { await control.finish() } }
        await control.arm()
        let scan = Task { await handle.refresh(quiet: true) }
        try await waitForPending(control)
        await control.advance(0.35)
        for _ in 0..<100 where handle.loading?.reported != 0.35 { try await Task.sleep(for: .milliseconds(5)) }
        let started = handle.loading?.started
        handle.setWatched(true, screenVisible: false)
        handle.setWatched(true, screenVisible: true)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(handle.isRefreshing)
        XCTAssertEqual(handle.loading?.reported, 0.35)
        XCTAssertEqual(handle.loading?.started, started)
        await control.finish(); await scan.value
    }

    func testCoveredReadCompletesIntoCacheAndReactivationRestoresObserversWithoutPolling() async throws {
        let directory = try Fixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let original = ModuleHandle.isAppActive, activity = Activity()
        ModuleHandle.isAppActive = { activity.active }; defer { ModuleHandle.isAppActive = original }
        let control = FocusScanControl(), handle = try await handle(directory, control: control)
        defer { handle.deactivate(); Task { await control.finish() } }
        await control.arm()
        let scan = Task { await handle.refresh(quiet: true) }
        try await waitForPending(control)
        handle.setWatched(false, screenVisible: false, windowVisible: true)
        await control.finish(); await scan.value
        XCTAssertEqual(handle.screen?.title, "1")
        XCTAssertFalse(handle.isWatched)
        XCTAssertFalse(handle.isRefreshing)
        var active = await control.active
        XCTAssertTrue(active)
        activity.active = false; handle.appResignedActive()
        for _ in 0..<100 { if await !control.active { break }; try await Task.sleep(for: .milliseconds(5)) }
        active = await control.active
        XCTAssertFalse(active)
        await control.arm()
        activity.active = true; handle.appBecameActive()
        for _ in 0..<100 { if await control.active { break }; try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(30))
        active = await control.active
        let pending = await control.pending
        XCTAssertTrue(active)
        XCTAssertFalse(pending, "A covered module may observe changes without starting another read")
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
        handle.hiddenReadGrace = .zero
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

    func testClosingBeforeFirstProgressKeepsTrackingTheHiddenRead() async throws {
        let directory = try Fixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let control = FocusScanControl(), handle = try await handle(directory, control: control)
        defer { handle.deactivate(); Task { await control.finish() } }
        await control.arm(initialProgress: false)
        let scan = Task { await handle.refresh(quiet: true) }
        try await waitForPending(control)
        XCTAssertNil(handle.loading)
        handle.setWatched(false, screenVisible: false)
        await control.advance(0.45)
        for _ in 0..<100 where handle.loading?.reported != 0.45 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(handle.loading?.reported, 0.45)
        handle.setWatched(true, screenVisible: true)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(handle.loading?.reported, 0.45)
        let cancellations = await control.cancellations
        XCTAssertEqual(cancellations, 0)
        await control.finish(); await scan.value
    }

    func testHiddenReadDeadlineCancelsAndCannotPublishItsInterruptedReply() async throws {
        let directory = try Fixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let control = FocusScanControl(), handle = try await handle(directory, control: control)
        defer { handle.deactivate(); Task { await control.finish() } }
        handle.hiddenReadGrace = .milliseconds(60)
        await control.arm()
        let scan = Task { await handle.refresh(quiet: true) }
        try await waitForPending(control)
        handle.setWatched(false, screenVisible: false)
        XCTAssertTrue(handle.isRefreshing, "Closing starts grace rather than canceling the read")
        await scan.value
        let cancellations = await control.cancellations
        XCTAssertEqual(cancellations, 1)
        XCTAssertEqual(handle.screen?.title, "0", "The expired read's cancelled reply must not replace the cache")
        XCTAssertNil(handle.loading)
        XCTAssertFalse(handle.isRefreshing)
    }

    func testReopeningCancelsTheOldDeadlineBeforeAnotherWindowClose() async throws {
        let directory = try Fixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let control = FocusScanControl(), handle = try await handle(directory, control: control)
        defer { handle.deactivate(); Task { await control.finish() } }
        await control.arm()
        let scan = Task { await handle.refresh(quiet: true) }
        try await waitForPending(control)
        handle.hiddenReadGrace = .milliseconds(20)
        handle.setWatched(false, screenVisible: false)
        handle.setWatched(true, screenVisible: true)
        handle.hiddenReadGrace = .seconds(5)
        handle.setWatched(false, screenVisible: false)
        try await Task.sleep(for: .milliseconds(100))
        let cancellations = await control.cancellations
        XCTAssertEqual(cancellations, 0, "The cancelled first deadline cannot expire the new grace period")
        await control.finish(); await scan.value
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
