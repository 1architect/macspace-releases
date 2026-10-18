import XCTest
import MacSpaceSdk
@testable import MacSpaceApp

private actor RowCleanupControl {
    var reads = 0
    var request: ActionRequest?
    private var continuation: CheckedContinuation<Void, Never>?
    func read() { reads += 1 }
    func wait(_ request: ActionRequest) async {
        self.request = request
        await withCheckedContinuation { continuation = $0 }
    }
    func finish() { continuation?.resume(); continuation = nil }
}

private struct RowCleanupModule: MacSpaceModule {
    let control: RowCleanupControl
    init() { control = RowCleanupControl() }
    init(control: RowCleanupControl) { self.control = control }
    func tile(context: ModuleContext) async -> Tile { await control.read(); return Tile(title: "Before", status: "measured") }
    func screen(context: ModuleContext) async -> Screen { await control.read(); return Screen(title: "Before", widgets: []) }
    func perform(_ request: ActionRequest, context: ModuleContext, progress: @escaping ProgressSink) async -> ActionResult {
        progress(ActionProgress(fraction: 0.5, message: "Freeing"))
        await control.wait(request)
        return ActionResult(outcome: .succeeded, message: "Freed", freedBytes: 5,
                            presentation: ModulePresentation(tile: Tile(title: "After", status: "measured"), screen: Screen(title: "After", widgets: [])))
    }
}

@MainActor
final class RowCleanupTests: XCTestCase {
    func testMissingPermissionStaysOnTheInitiatingRow() async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Fixtures.writeBundle(Fixtures.manifest(), name: "Test", into: directory)
        let descriptor = try XCTUnwrap(ModuleScanner.scan(directory: directory).modules.first)
        let handle = ModuleHandle(descriptor: descriptor, settings: SettingsStore(defaults: Fixtures.defaults()),
                                  permissions: FakePermissions(states: [.fullDiskAccess: .missing]), loader: { _ in FakeModule() })
        await handle.activate()
        defer { handle.deactivate() }
        _ = await handle.perform(Action(id: "clean", title: "Free", requires: [.fullDiskAccess]), rowID: "item")
        XCTAssertEqual(handle.resultRowID, "item")
        XCTAssertEqual(handle.rowResult?.outcome, .needsAttention)
        XCTAssertNil(handle.lastResult)
        XCTAssertFalse(handle.isShowingCompletion)
    }

    func testPageCleanupKeepsTheCurrentPresentationUntilVerifiedValuesArrive() async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Fixtures.writeBundle(Fixtures.manifest(), name: "Test", into: directory)
        let descriptor = try XCTUnwrap(ModuleScanner.scan(directory: directory).modules.first)
        let control = RowCleanupControl()
        let handle = ModuleHandle(descriptor: descriptor, settings: SettingsStore(defaults: Fixtures.defaults()), permissions: FakePermissions(),
                                  loader: { _ in RowCleanupModule(control: control) })
        await handle.activate()
        defer { handle.deactivate() }
        let reads = await control.reads
        let action = Task { await handle.perform(Action(id: "clean", title: "Free")) }
        for _ in 0..<100 {
            if await control.request != nil, handle.progress != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(handle.isCleaning, "the graph and action fill still animate")
        XCTAssertFalse(handle.isReloading, "cleanup cannot enter the initial-load details cascade")
        XCTAssertEqual(handle.screen?.title, "Before")
        XCTAssertEqual(handle.tile?.title, "Before")
        await control.finish()
        _ = await action.value
        XCTAssertEqual(handle.screen?.title, "After")
        XCTAssertEqual(handle.tile?.title, "After")
        let after = await control.reads
        XCTAssertEqual(after, reads)
    }

    func testRowCleanupStaysInlineAndAppliesVerifiedPresentationWithoutAnotherScan() async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Fixtures.writeBundle(Fixtures.manifest(), name: "Test", into: directory)
        let descriptor = try XCTUnwrap(ModuleScanner.scan(directory: directory).modules.first)
        let control = RowCleanupControl()
        let module = RowCleanupModule(control: control)
        let handle = ModuleHandle(descriptor: descriptor, settings: SettingsStore(defaults: Fixtures.defaults()), permissions: FakePermissions(), loader: { _ in module })
        await handle.activate()
        defer { handle.deactivate() }
        let reads = await control.reads
        let action = Task { await handle.perform(Action(id: "clean", title: "Free"), rowID: "item") }
        for _ in 0..<100 {
            if await control.request != nil, handle.progress != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(handle.runningRowID, "item")
        XCTAssertEqual(handle.progress?.fraction, 0.5)
        XCTAssertFalse(handle.isCleaning, "row actions cannot hide details or start a full-page cleaning animation")
        XCTAssertFalse(handle.isRefreshing)
        XCTAssertEqual(handle.screen?.title, "Before")
        await control.finish()
        _ = await action.value
        let after = await control.reads
        XCTAssertEqual(after, reads, "verified target updates must not cause a full module scan")
        XCTAssertEqual(handle.tile?.title, "After")
        XCTAssertEqual(handle.screen?.title, "After")
        XCTAssertEqual(handle.allDone, 0)
        XCTAssertFalse(handle.isShowingCompletion)
        XCTAssertNil(handle.lastResult)
        XCTAssertEqual(handle.resultRowID, "item")
        XCTAssertEqual(handle.rowResult?.outcome, .succeeded)
        XCTAssertNil(handle.runningRowID)
        let request = await control.request
        XCTAssertEqual(request?.rowID, "item")
    }
}

private struct ContinuingCleanupModule: MacSpaceModule {
    let control: RowCleanupControl
    var outcome: ActionResult.Outcome = .succeeded
    var backgroundPath = "/target"
    init() { control = RowCleanupControl() }
    init(control: RowCleanupControl, outcome: ActionResult.Outcome = .succeeded, backgroundPath: String = "/target") {
        self.control = control
        self.outcome = outcome
        self.backgroundPath = backgroundPath
    }
    private func action(_ path: String) -> Action { Action(id: "clean", title: "Free", parameters: ["path": path]) }
    func tile(context: ModuleContext) async -> Tile { await control.read(); return Tile(title: "Before", status: "measured") }
    func screen(context: ModuleContext) async -> Screen {
        await control.read()
        return Screen(title: "Before", primary: action("/target"), widgets: [.list(ListWidget(id: "rows", rows: [Row(id: "item", title: "Files", actions: [action("/target")])]))])
    }
    func perform(_ request: ActionRequest, context: ModuleContext, progress: @escaping ProgressSink) async -> ActionResult {
        progress(ActionProgress(fraction: 0.5, message: "Freeing"))
        await control.wait(request)
        var row = Row(id: "item", title: "Files", actions: [action(backgroundPath)])
        row.activity = ActionProgress(message: "Freeing in the background")
        return ActionResult(outcome: outcome, message: "Freed 5 bytes", freedBytes: 5,
                            presentation: ModulePresentation(tile: Tile(title: "After", status: "freeing"),
                                                             screen: Screen(title: "After", widgets: [.list(ListWidget(id: "rows", rows: [row]))])))
    }
}

@MainActor
final class CleanupHandoffTests: XCTestCase {
    private func perform(rowID: String?, outcome: ActionResult.Outcome = .succeeded, backgroundPath: String = "/target") async throws -> ModuleHandle {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Fixtures.writeBundle(Fixtures.manifest(), name: "Test", into: directory)
        let descriptor = try XCTUnwrap(ModuleScanner.scan(directory: directory).modules.first)
        let control = RowCleanupControl()
        let module = ContinuingCleanupModule(control: control, outcome: outcome, backgroundPath: backgroundPath)
        let handle = ModuleHandle(descriptor: descriptor, settings: SettingsStore(defaults: Fixtures.defaults()), permissions: FakePermissions(), loader: { _ in module })
        await handle.activate()
        let before = await control.reads
        let action = Task { await handle.perform(Action(id: "clean", title: "Free", parameters: ["path": "/target"]), rowID: rowID) }
        for _ in 0..<100 {
            if await control.request != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        await control.finish()
        let result = await action.value
        XCTAssertEqual(result?.freedBytes, 5, "verified savings and history data survive the UI handoff")
        let after = await control.reads
        XCTAssertEqual(after, before, "background handoff uses the verified presentation without a new scan")
        return handle
    }

    func testBothEntryPointsHandBackgroundWorkToTheOriginalRowWithoutAnotherResult() async throws {
        for rowID: String? in [nil, "item"] {
            let handle = try await perform(rowID: rowID)
            defer { handle.deactivate() }
            XCTAssertNil(handle.screen?.primary)
            XCTAssertNotNil(handle.screen?.activeRow(for: ActionRequest(actionID: "clean", parameters: ["path": "/target"])))
            XCTAssertNil(handle.lastResult, "the dock has no completion result to keep it on screen")
            XCTAssertNil(handle.rowResult, "the continuing flag is the one inline presentation")
            XCTAssertNil(handle.resultRowID)
            XCTAssertEqual(handle.allDone, 0)
            XCTAssertFalse(handle.isShowingCompletion, "ongoing background work is not All done")
        }
    }

    func testAnUnrelatedBackgroundTargetCannotSuppressCompletion() async throws {
        let handle = try await perform(rowID: nil, backgroundPath: "/another-target")
        defer { handle.deactivate() }
        XCTAssertEqual(handle.allDone, 1)
    }

    func testFailuresRemainVisibleEvenWhenTheSameRowHasBackgroundActivity() async throws {
        let row = try await perform(rowID: "item", outcome: .failed)
        defer { row.deactivate() }
        XCTAssertEqual(row.rowResult?.outcome, .failed)
        let page = try await perform(rowID: nil, outcome: .failed)
        defer { page.deactivate() }
        XCTAssertEqual(page.lastResult?.outcome, .failed)
        XCTAssertEqual(page.allDone, 0)
    }
}
