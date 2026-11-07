import XCTest
import MacSpaceSdk
@testable import MacSpaceApp

@MainActor
final class LiveActionSecurityTests: XCTestCase {
    private struct Module: MacSpaceModule {
        var action = Action(id: "fixture", title: "fixture")
        var calls = Calls()
        func tile(context: ModuleContext) async -> Tile { Tile(title: "fixture", status: "ready", switchAction: action) }
        func screen(context: ModuleContext) async -> Screen { Screen(title: "fixture", primary: action, widgets: []) }
        func perform(_ request: ActionRequest, context: ModuleContext, progress: @escaping ProgressSink) async -> ActionResult {
            calls.add("perform:" + request.actionID); return ActionResult(outcome: .succeeded, message: "", refresh: false)
        }
    }
    private func make(action: Action, permissions: FakePermissions = FakePermissions(), confirm: @escaping @MainActor (Action) -> Bool = { _ in true }) async throws -> (ModuleHandle, Calls) {
        let folder = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let bundle = try Fixtures.writeBundle(Fixtures.manifest(), name: "fixture", into: folder)
        let descriptor = ModuleScanner.scan(directory: folder).modules.first!
        _ = bundle
        let calls = Calls()
        let handle = ModuleHandle(confirm: confirm, descriptor: descriptor, settings: SettingsStore(defaults: Fixtures.defaults()), permissions: permissions, loader: { _ in Module(action: action, calls: calls) })
        await handle.activate(); await handle.refresh()
        return (handle, calls)
    }
    func testCachedSummaryDropsActionsIncludingNestedGraphCapabilities() throws {
        let defaults = Fixtures.defaults(), settings = SettingsStore(defaults: defaults), action = Action(id: "danger", title: "Delete")
        let tile = Tile(title: "cached", status: "old", graphic: .blocks([UsageSegment(id: "s", label: "s", bytes: 1, tone: .neutral,
            items: [Row(id: "r", title: "r", actions: [action])], contextActions: .init(delete: action))]), switchAction: action, freeAction: action)
        defaults.set(try JSONEncoder().encode(tile), forKey: "module.m.lastTile")
        settings.setLastTile(tile, module: "m")
        let cached = try XCTUnwrap(settings.lastTile(module: "m"))
        XCTAssertNil(cached.switchAction); XCTAssertNil(cached.freeAction)
        if case let .blocks(parts) = cached.graphic { XCTAssertTrue(parts[0].items.isEmpty); XCTAssertNil(parts[0].contextActions) } else { XCTFail() }
        let stored = try XCTUnwrap(defaults.data(forKey: "module.m.lastTile"))
        XCTAssertFalse(String(decoding: stored, as: UTF8.self).contains("danger"))
    }
    func testForgedOperationParametersPermissionAndConfirmationNeverDispatch() async throws {
        let action = Action(id: "toggle", title: "T", parameters: ["scope": "safe"], requires: [.fullDiskAccess])
        let (handle, calls) = try await make(action: action)
        var forged = action; forged.id = "delete"; _ = await handle.perform(forged)
        forged = action; forged.parameters["scope"] = "other"; _ = await handle.perform(forged)
        forged = action; forged.requires = []; _ = await handle.perform(forged)
        _ = await handle.perform(action, extraParameters: ["scope": "other"])
        XCTAssertTrue(calls.all.isEmpty)
    }
    func testUnknownAndMissingPermissionsBlockManualSwitchAndGrantedRuns() async throws {
        for status in [PermissionStatus.unknown, .missing, .granted] {
            let action = Action(id: "toggle", title: "T", requires: [.fullDiskAccess])
            let (handle, calls) = try await make(action: action, permissions: FakePermissions(states: [.fullDiskAccess: status]))
            _ = await handle.performTileSwitch(action, value: true)
            XCTAssertEqual(calls.all.count, status == .granted ? 1 : 0)
        }
    }
    func testDashboardRequiresConfirmationAndCancellationCannotDispatch() async throws {
        let action = Action(id: "toggle", title: "T", confirmation: Confirmation(title: "Confirm", message: "Fixture", confirmTitle: "Continue"))
        var confirmations = 0
        let (handle, calls) = try await make(action: action, confirm: { received in confirmations += 1; XCTAssertEqual(received, action); return false })
        _ = await handle.performTileSwitch(action, value: true)
        XCTAssertEqual(confirmations, 1); XCTAssertTrue(calls.all.isEmpty)
    }
}
