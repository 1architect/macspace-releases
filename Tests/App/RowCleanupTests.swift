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
