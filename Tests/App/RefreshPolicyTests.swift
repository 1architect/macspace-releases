import XCTest
import MacSpaceSdk
@testable import MacSpaceApp

private actor PresentationReads {
    var events: [String] = []
    var hasStatus = false
    func enableStatus() { hasStatus = true }
    func record(_ event: String) { events.append(event) }
}

private struct PresentationModule: MacSpaceModule {
    let reads: PresentationReads
    init() { reads = PresentationReads() }
    init(reads: PresentationReads) { self.reads = reads }
    static var page: Screen {
        let group = Row(id: "group", title: "Group", children: [Row(id: "a", title: "A")],
                        selection: Selection(action: Action(id: "clean", title: "Clean"), choices: ["a": 1], checked: ["a"]))
        return Screen(title: "Page", widgets: [.list(ListWidget(id: "items", rows: [group]))])
    }
    func tile(context: ModuleContext) async -> Tile {
        await reads.record("tile")
        return Tile(title: "Tile", status: "measured")
    }
    func tile(context: ModuleContext, progress: @escaping LoadProgressSink) async -> Tile { await tile(context: context) }
    func screen(context: ModuleContext) async -> Screen {
        await reads.record("screen")
        return Self.page
    }
    func status(context: ModuleContext) async -> (tile: Tile, screen: Screen)? {
        await reads.record("status")
        return await reads.hasStatus ? (Tile(title: "Tile", status: "live counter"), Self.page) : nil
    }
    func invalidate() async { await reads.record("invalidate") }
    func perform(_ request: ActionRequest, context: ModuleContext, progress: @escaping ProgressSink) async -> ActionResult { .succeeded("") }
}

@MainActor
final class RefreshPolicyTests: XCTestCase {
    private func makeHandle(_ directory: URL, reads: PresentationReads) async throws -> ModuleHandle {
        try Fixtures.writeBundle(Fixtures.manifest(), name: "Test", into: directory)
        let descriptor = try XCTUnwrap(ModuleScanner.scan(directory: directory).modules.first)
        let module = PresentationModule(reads: reads)
        let handle = ModuleHandle(descriptor: descriptor, settings: SettingsStore(defaults: Fixtures.defaults()), permissions: FakePermissions(), loader: { _ in module })
        await handle.activate()
        return handle
    }

    func testAutomaticStatusPreservesOpenGroupAndChoiceAndExplicitRefreshBypassesIt() async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reads = PresentationReads()
        let handle = try await makeHandle(directory, reads: reads)
        defer { handle.deactivate() }
        let group = try XCTUnwrap(ScreenView.row("group", in: PresentationModule.page))
        handle.pushGroup(group.id)
        handle.toggle("a", in: group)
        await reads.enableStatus()
        let before = await reads.events.count
        await handle.refresh(quiet: true)
        let statusEvents = await reads.events
        XCTAssertEqual(Array(statusEvents.dropFirst(before)), ["status"], "no tile/page scan during a live counter update")
        XCTAssertEqual(handle.tile?.status, "live counter")
        XCTAssertEqual(handle.groupPath, ["group"])
        XCTAssertTrue(handle.checked(group).isEmpty, "an automatic update preserves the user's choice")
        XCTAssertFalse(handle.isRefreshing)
        XCTAssertFalse(handle.isReloading)
        XCTAssertNil(handle.loading)
        let checkpoint = statusEvents.count
        await handle.refresh(reload: true)
        let explicitEvents = await reads.events
        XCTAssertEqual(Set(explicitEvents.dropFirst(checkpoint)), ["invalidate", "tile", "screen"])
        XCTAssertEqual(handle.tile?.status, "measured")
    }

    func testDashboardRefreshReadsOnlyTheTile() async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reads = PresentationReads()
        let handle = try await makeHandle(directory, reads: reads)
        defer { handle.deactivate() }
        handle.setWatched(true, screenVisible: false)
        let before = await reads.events.count
        await handle.refresh(quiet: true)
        let after = await reads.events
        XCTAssertEqual(Array(after.dropFirst(before)), ["status", "tile"])
        XCTAssertEqual(handle.screen?.title, "Page", "a tile-only update retains the previous page for navigation")
    }

    func testWindowDestinationsCombineWithoutPollingHiddenModules() async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Fixtures.writeBundle(Fixtures.manifest(id: "com.test.a"), name: "A", into: directory)
        try Fixtures.writeBundle(Fixtures.manifest(id: "com.test.b"), name: "B", into: directory)
        let host = ModuleHost(modulesDirectory: directory, settings: SettingsStore(defaults: Fixtures.defaults()),
                              permissions: FakePermissions(), privileged: nil, loader: { _ in FakeModule() })
        let first = UUID(), second = UUID()
        host.setVisibleDestination(.module("com.test.a"), for: first)
        await host.reload()
        let a = try XCTUnwrap(host.handle(for: "com.test.a")), b = try XCTUnwrap(host.handle(for: "com.test.b"))
        defer { a.deactivate(); b.deactivate(); host.scheduler.stopAll() }
        XCTAssertTrue(a.isWatched && a.screenIsVisible)
        XCTAssertFalse(b.isWatched)
        XCTAssertNil(b.screen, "a hidden module is loaded without an unnecessary initial scan")
        host.setVisibleDestination(.home, for: second)
        XCTAssertTrue(a.isWatched && a.screenIsVisible)
        XCTAssertTrue(b.isWatched)
        XCTAssertFalse(b.screenIsVisible)
        host.setVisibleDestination(.settings, for: first)
        XCTAssertTrue(a.isWatched)
        XCTAssertFalse(a.screenIsVisible)
        host.setVisibleDestination(nil, for: second)
        XCTAssertFalse(a.isWatched || b.isWatched, "Settings does not poll modules")
        host.setVisibleDestination(nil, for: first)
        XCTAssertFalse(a.isWatched || b.isWatched, "closing the last canvas does not re-enable all modules")
    }
}
