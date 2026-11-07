import XCTest
import MacSpaceSdk
@testable import MacSpaceApp

private struct GraphActionModule: MacSpaceModule {
    enum Source: CaseIterable, Sendable { case hero, usage, tile }
    var source: Source = .hero
    var calls = Calls()
    init() {}
    init(source: Source, calls: Calls) { self.source = source; self.calls = calls }
    static let deletion = Action(id: "deleteFolder", title: "Remove", parameters: ["path": "/fixture/child"])
    private var segment: UsageSegment {
        UsageSegment(id: "folder", label: "Folder", bytes: 1, tone: .neutral, pageID: "folder:child", contextActions: GraphContextActions(delete: Self.deletion))
    }
    func tile(context: ModuleContext) async -> Tile { Tile(title: "Fixture", status: "Ready", graphic: source == .tile ? .blocks([segment]) : nil) }
    func screen(context: ModuleContext) async -> Screen {
        let usage = UsageBar(id: "hero", title: "Fixture", segments: [segment])
        return Screen(title: "Fixture", hero: source == .hero ? usage : nil, widgets: source == .usage ? [.usage(usage)] : [])
    }
    func perform(_ request: ActionRequest, context: ModuleContext, progress: @escaping ProgressSink) async -> ActionResult {
        calls.add("perform:" + request.actionID); return ActionResult(outcome: .succeeded, message: "Inert", refresh: false)
    }
}
private actor QueuedActionControl {
    private var continuation: CheckedContinuation<Void, Never>?
    var started = false
    func wait() async { started = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
private struct QueuedActionModule: MacSpaceModule {
    var control = QueuedActionControl()
    var calls = Calls()
    init() {}
    init(control: QueuedActionControl, calls: Calls) { self.control = control; self.calls = calls }
    static func screen(_ title: String) -> Screen {
        Screen(title: title, widgets: [.list(ListWidget(id: "items", rows: [Row(id: "a", title: "A", actions: [Action(id: "a", title: "A")]), Row(id: "b", title: "B", actions: [Action(id: "b", title: "B")])]))])
    }
    func tile(context: ModuleContext) async -> Tile { Tile(title: "Queue", status: "Ready") }
    func screen(context: ModuleContext) async -> Screen { Self.screen("Before") }
    func perform(_ request: ActionRequest, context: ModuleContext, progress: @escaping ProgressSink) async -> ActionResult {
        calls.add(request.actionID)
        if request.actionID == "a" { await control.wait() }
        return ActionResult(outcome: .succeeded, message: "Done", refresh: false, presentation: ModulePresentation(tile: Tile(title: "Queue", status: "Ready"), screen: Self.screen("After")))
    }
}
@MainActor
final class LiveActionDispatchRegressionTests: XCTestCase {
    private func handle(_ directory: URL, module: any MacSpaceModule, confirm: @escaping @MainActor (Action) -> Bool = { _ in true }) async throws -> ModuleHandle {
        try Fixtures.writeBundle(Fixtures.manifest(), name: "Fixture", into: directory)
        let descriptor = try XCTUnwrap(ModuleScanner.scan(directory: directory).modules.first)
        let handle = ModuleHandle(confirm: confirm, descriptor: descriptor, settings: SettingsStore(defaults: Fixtures.defaults()), permissions: FakePermissions(), loader: { _ in module })
        await handle.activate(); return handle
    }
    func testFreshGraphCapabilitiesDispatchFromEveryPublishedGraphSource() async throws {
        for source in GraphActionModule.Source.allCases {
            let directory = try Fixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
            let calls = Calls()
            var confirmations = 0
            let handle = try await handle(directory, module: GraphActionModule(source: source, calls: calls), confirm: { action in
                confirmations += 1; XCTAssertEqual(action.role, .destructive); XCTAssertNotNil(action.confirmation); return true
            })
            let action = try XCTUnwrap(GraphMenuPolicy.deletion(GraphActionModule.deletion, label: "Folder"))
            XCTAssertNotNil(handle.trustedAction(action))
            var forged = action; forged.parameters["path"] = "/different"
            _ = await handle.perform(forged); XCTAssertTrue(calls.all.isEmpty)
            _ = await handle.perform(action)
            XCTAssertEqual(calls.all, ["perform:deleteFolder"]); XCTAssertEqual(confirmations, 1)
            handle.deactivate()
        }
    }
    func testRejectingStaleQueuedActionClearsItsWorkingFlagWithoutExecutingIt() async throws {
        let directory = try Fixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let control = QueuedActionControl(), calls = Calls()
        let handle = try await handle(directory, module: QueuedActionModule(control: control, calls: calls))
        defer { handle.deactivate() }
        let first = Task { await handle.perform(Action(id: "a", title: "A"), rowID: "a") }
        for _ in 0..<100 { if await control.started { break }; await Task.yield() }
        let second = Task { await handle.perform(Action(id: "b", title: "B"), rowID: "b") }
        for _ in 0..<100 { if handle.queuedRows["b"] != nil { break }; await Task.yield() }
        XCTAssertNotNil(handle.queuedRows["b"])
        await control.release(); _ = await first.value; _ = await second.value
        XCTAssertNil(handle.queuedRows["b"]); XCTAssertEqual(calls.all, ["a"])
    }
}
