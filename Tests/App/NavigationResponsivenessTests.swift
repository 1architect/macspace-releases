import MacSpaceSdk
import XCTest
@testable import MacSpaceApp

private actor NavigationReadControl {
    enum Kind { case tile, screen }
    var tiles = 0
    var screens = 0
    var invalidations = 0
    private var hold: Kind?
    private var continuation: CheckedContinuation<Void, Never>?
    private var reports: LoadProgressSink?
    var pending: Bool { continuation != nil }
    func arm(_ kind: Kind) { hold = kind }
    func invalidate() { invalidations += 1 }
    private func pause(_ kind: Kind, progress: @escaping LoadProgressSink) async {
        guard hold == kind else { return }
        hold = nil; reports = progress; progress(0)
        await withCheckedContinuation { continuation = $0 }
    }
    func tile(_ progress: @escaping LoadProgressSink) async -> Tile {
        tiles += 1
        await pause(.tile, progress: progress)
        return Tile(title: "Fixture", status: "Ready")
    }
    func screen(flag: Bool, progress: @escaping LoadProgressSink) async -> Screen {
        screens += 1
        let version = invalidations
        await pause(.screen, progress: progress)
        return Screen(title: "v:\(version);flag:\(flag)", widgets: [])
    }
    func advance(_ value: Double) { reports?(value) }
    func finish() { reports?(1); reports = nil; continuation?.resume(); continuation = nil }
}

private struct NavigationReadModule: MacSpaceModule {
    let control: NavigationReadControl
    init() { control = NavigationReadControl() }
    init(_ control: NavigationReadControl) { self.control = control }
    func tile(context: ModuleContext) async -> Tile { await control.tile({ _ in }) }
    func tile(context: ModuleContext, progress: @escaping LoadProgressSink) async -> Tile { await control.tile(progress) }
    func screen(context: ModuleContext) async -> Screen { await control.screen(flag: context.options.bool("flag"), progress: { _ in }) }
    func screen(context: ModuleContext, progress: @escaping LoadProgressSink) async -> Screen { await control.screen(flag: context.options.bool("flag"), progress: progress) }
    func invalidate() async { await control.invalidate() }
    func perform(_ request: ActionRequest, context: ModuleContext, progress: @escaping ProgressSink) async -> ActionResult { .failed("Read-only fixture") }
}

@MainActor
final class NavigationResponsivenessTests: XCTestCase {
    private func handle(_ directory: URL, _ control: NavigationReadControl, tileOnly: Bool = false, warmup: Duration = .zero) throws -> ModuleHandle {
        try Fixtures.writeBundle(Fixtures.manifest(), name: "Fixture", into: directory)
        let descriptor = try XCTUnwrap(ModuleScanner.scan(directory: directory).modules.first)
        let handle = ModuleHandle(confirm: { _ in true }, descriptor: descriptor, settings: SettingsStore(defaults: Fixtures.defaults()), permissions: FakePermissions(), loader: { _ in NavigationReadModule(control) })
        handle.dashboardWarmupDelay = warmup
        handle.setWatched(true, screenVisible: !tileOnly)
        return handle
    }
    private func until(_ condition: () async -> Bool) async throws {
        for _ in 0..<1_000 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Read did not reach its expected state")
        throw CancellationError()
    }

    func testCachedReopeningRemainsInteractiveAndRepeatedVisitsJoinTheRead() async throws {
        let directory = try Fixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let control = NavigationReadControl(), handle = try handle(directory, control)
        defer { handle.deactivate(); Task { await control.finish() } }
        await handle.activate()
        let cached = handle.screen
        await control.arm(.screen)
        handle.setWatched(true, screenVisible: false)
        handle.setWatched(true, screenVisible: true)
        try await until { await control.pending }
        for _ in 0..<5 {
            handle.setWatched(true, screenVisible: false)
            handle.setWatched(true, screenVisible: true)
        }
        let joined = Task { await handle.refresh(quiet: true) }
        await control.advance(0.8)
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertEqual(handle.screen, cached)
        XCTAssertFalse(handle.isBusy)
        XCTAssertFalse(handle.isRefreshing)
        XCTAssertFalse(handle.isReloading)
        XCTAssertNil(handle.loading)
        let screens = await control.screens
        XCTAssertEqual(screens, 2, "One initial page and one shared navigation refresh")
        await control.finish(); await joined.value
        XCTAssertEqual(handle.screen, cached)
    }

    func testOpeningDuringATileOnlyReadStillFetchesThePage() async throws {
        let directory = try Fixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let control = NavigationReadControl(), handle = try handle(directory, control, tileOnly: true)
        defer { handle.deactivate(); Task { await control.finish() } }
        await control.arm(.tile)
        let tile = Task { await handle.activate() }
        try await until { await control.pending }
        XCTAssertNil(handle.screen)
        handle.setWatched(true, screenVisible: true)
        await control.finish(); await tile.value
        try await until { handle.screen != nil }
        let screens = await control.screens
        XCTAssertEqual(screens, 1)
    }

    func testExplicitRefreshSupersedesAnOlderNavigationReadAndRejectsItsLateResult() async throws {
        let directory = try Fixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let control = NavigationReadControl(), handle = try handle(directory, control)
        defer { handle.deactivate(); Task { await control.finish() } }
        await handle.activate()
        await control.arm(.screen)
        let old = Task { await handle.refresh(quiet: true) }
        try await until { await control.pending }
        await handle.refresh(reload: true)
        XCTAssertEqual(handle.screen?.title, "v:1;flag:true")
        await control.advance(0.7); await control.finish(); await old.value
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(handle.screen?.title, "v:1;flag:true")
        XCTAssertFalse(handle.isRefreshing)
        XCTAssertNil(handle.loading)
    }

    func testAnOptionChangeCannotJoinAPresentationFromBeforeThatChange() async throws {
        let directory = try Fixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let control = NavigationReadControl(), handle = try handle(directory, control)
        defer { handle.deactivate(); Task { await control.finish() } }
        await handle.activate()
        await control.arm(.screen)
        let old = Task { await handle.refresh(quiet: true) }
        try await until { await control.pending }
        handle.settings.setOption(.bool(false), "flag", module: handle.id)
        await handle.refreshAfterChange()
        XCTAssertEqual(handle.screen?.title, "v:0;flag:false")
        await control.finish(); await old.value
        XCTAssertEqual(handle.screen?.title, "v:0;flag:false")
    }

    func testRecentTileDoesNotMakeAnOldPageFreshOnActivation() async throws {
        let directory = try Fixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let control = NavigationReadControl(), handle = try handle(directory, control)
        defer { handle.deactivate(); Task { await control.finish() } }
        var now = Date()
        handle.refreshClock = { now }
        await handle.activate()
        now.addTimeInterval(61)
        handle.setWatched(true, screenVisible: false)
        await handle.refresh(quiet: true)
        await control.arm(.screen)
        handle.setWatched(true, screenVisible: true)
        try await until { await control.pending }
        XCTAssertEqual(handle.presentationAge, 61, accuracy: 0.01, "A fresh tile must not advance the page's measurement age")
        let before = await control.screens
        handle.appBecameActive()
        await control.finish()
        try await Task.sleep(for: .milliseconds(30))
        let after = await control.screens
        XCTAssertEqual(after, before, "Activation joins the current page refresh")
    }

    func testDashboardWarmupWaitsAndNeverConstructsAPage() async throws {
        let directory = try Fixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let control = NavigationReadControl(), handle = try handle(directory, control, tileOnly: true, warmup: .milliseconds(60))
        defer { handle.deactivate() }
        await handle.activate()
        let before = await control.tiles
        XCTAssertEqual(before, 0)
        try await until { await control.tiles == 1 }
        let screens = await control.screens
        XCTAssertEqual(screens, 0)
        XCTAssertNil(handle.screen)
    }

    func testDirectVisitStartsWarmupImmediatelyAndDoesNotLeaveADelayedDuplicate() async throws {
        let directory = try Fixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let control = NavigationReadControl(), handle = try handle(directory, control, tileOnly: true, warmup: .milliseconds(80))
        defer { handle.deactivate() }
        await handle.activate()
        handle.setWatched(true, screenVisible: true)
        try await until { handle.screen != nil }
        try await Task.sleep(for: .milliseconds(120))
        let tiles = await control.tiles, screens = await control.screens
        XCTAssertEqual(tiles, 1)
        XCTAssertEqual(screens, 1)
    }

    func testLosingTheLastWindowCancelsPendingWarmupAndVisibilityCanRetryIt() async throws {
        let directory = try Fixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let control = NavigationReadControl(), handle = try handle(directory, control, tileOnly: true, warmup: .milliseconds(40))
        defer { handle.deactivate() }
        await handle.activate()
        handle.setWatched(false, screenVisible: false)
        try await Task.sleep(for: .milliseconds(80))
        let hiddenReads = await control.tiles
        XCTAssertEqual(hiddenReads, 0)
        handle.setWatched(true, screenVisible: false)
        try await until { await control.tiles == 1 }
    }

    func testHomeDefersOnlyDiskWarmupAndAnotherWindowCanOpenItImmediately() async throws {
        let directory = try Fixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let disk = NavigationReadControl(), other = NavigationReadControl()
        try Fixtures.writeBundle(Fixtures.manifest(id: "com.macspace.disk-map"), name: "Disk", into: directory)
        try Fixtures.writeBundle(Fixtures.manifest(id: "com.test.other"), name: "Other", into: directory)
        let host = ModuleHost(modulesDirectory: directory, settings: SettingsStore(defaults: Fixtures.defaults()), permissions: FakePermissions(), privileged: nil,
                              loader: { descriptor in NavigationReadModule(descriptor.id == "com.macspace.disk-map" ? disk : other) })
        let home = UUID(), page = UUID()
        host.setVisibleDestination(.home, for: home)
        await host.reload()
        defer { host.handles.forEach { $0.deactivate() }; host.scheduler.stopAll() }
        let diskReads = await disk.tiles, otherReads = await other.tiles
        XCTAssertEqual(diskReads, 0)
        XCTAssertEqual(otherReads, 1)
        host.setVisibleDestination(.storage, for: page)
        try await until { host.handle(for: "com.macspace.disk-map")?.screen != nil }
        let finalDiskReads = await disk.tiles, pages = await disk.screens
        XCTAssertEqual(finalDiskReads, 1)
        XCTAssertEqual(pages, 1)
    }

    func testPageViewValuesSurviveReopeningAreBoundedAndClearOnDeactivation() throws {
        let directory = try Fixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let handle = try handle(directory, NavigationReadControl())
        let root = handle.pageViewState("screen:root")
        root.scrollY = 250; root.flippedSections = ["expanded"]
        let oldest = handle.pageViewState("page:0")
        for n in 1..<30 { _ = handle.pageViewState("page:\(n)") }
        XCTAssertTrue(handle.pageViewState("screen:root") === root)
        XCTAssertEqual(root.scrollY, 250)
        XCTAssertEqual(root.flippedSections, ["expanded"])
        XCTAssertFalse(handle.pageViewState("page:0") === oldest)
        handle.deactivate()
        XCTAssertEqual(handle.pageViewState("screen:root").scrollY, 0)
        XCTAssertTrue(handle.pageViewState("screen:root").flippedSections.isEmpty)
    }
}
