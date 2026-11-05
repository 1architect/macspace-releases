import XCTest
import MacSpaceSdk
@testable import MacSpaceApp

private struct CleanupSelectionModule: MacSpaceModule {
    let calls: Calls
    init() { calls = Calls() }
    init(calls: Calls) { self.calls = calls }
    func tile(context: ModuleContext) async -> Tile { Tile(title: "Cleanup", status: "") }
    func screen(context: ModuleContext) async -> Screen {
        let rows = ["safe", "optional"].map { id in
            Row(id: id, title: id).selectingCleanup(Action(id: "clean", title: "Free", parameters: ["id": id, "variant": context.options.bool("flag") ? "one" : "two"],
                confirmation: Confirmation(title: "Free " + id + "?", message: "Details for " + id, confirmTitle: "Free")),
                bytes: 100, defaultSelected: id == "safe")
        }
        return Screen(title: "Cleanup", hero: UsageBar(id: "usage", title: "Cleanup", segments: [UsageSegment(id: "all", label: "All", bytes: 200, tone: .caution, items: rows)]),
            widgets: [.list(ListWidget(id: "cleanups", rows: rows))])
    }
    func perform(_ request: ActionRequest, context: ModuleContext, progress: @escaping ProgressSink) async -> ActionResult {
        calls.add((request.parameters["automatic"] == "1" ? "auto:" : "manual:") + (request.parameters["id"] ?? ""))
        progress(.init(fraction: 1, message: "Done"))
        return ActionResult(outcome: .succeeded, message: "Done", refresh: false, freedBytes: 100)
    }
    func autoClean(context: ModuleContext) async -> CleanupReport? {
        await CleanupBatch.automatic(screen: screen(context: context), context: context, perform: perform)
    }
}

@MainActor
final class CleanupSelectionTests: XCTestCase {
    private func handle(_ settings: SettingsStore, _ calls: Calls) async throws -> ModuleHandle {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var manifest = Fixtures.manifest(); manifest.autoClean = true
        try Fixtures.writeBundle(manifest, name: "Cleanup", into: directory)
        let descriptor = try XCTUnwrap(ModuleScanner.scan(directory: directory).modules.first)
        let handle = ModuleHandle(descriptor: descriptor, settings: settings, permissions: FakePermissions(), loader: { _ in CleanupSelectionModule(calls: calls) })
        await handle.activate()
        return handle
    }
    private func action(_ handle: ModuleHandle) throws -> Action {
        guard case let .idle(action)? = ActionDock(handle: handle, isVisible: .constant(false)).phase else { throw NSError(domain: "Missing cleanup action", code: 1) }
        return action
    }
    func testChoicesPersistAcrossHandleRestartAndAutomaticCleanupUsesOnlyTheSavedSelection() async throws {
        let defaults = Fixtures.defaults(), calls = Calls()
        let first = try await handle(SettingsStore(defaults: defaults), calls)
        XCTAssertEqual(first.checked(try XCTUnwrap(first.activeSelection)), ["safe"])
        handleToggle("safe", first); handleToggle("optional", first)
        XCTAssertTrue(calls.all.isEmpty, "Checkbox changes save intent without cleaning anything")
        XCTAssertTrue(try action(first).confirmation?.message.contains("Details for optional") == true)
        XCTAssertFalse(try action(first).confirmation?.message.contains("Details for safe") == true)
        first.clearPageSelections(); first.deactivate()
        let second = try await handle(SettingsStore(defaults: defaults), calls)
        defer { second.deactivate() }
        XCTAssertEqual(second.checked(try XCTUnwrap(second.activeSelection)), ["optional"])
        let report = await second.autoClean()
        XCTAssertEqual(report?.freedBytes, 100)
        XCTAssertEqual(calls.all, ["auto:optional"])
        XCTAssertEqual(second.checked(try XCTUnwrap(second.activeSelection)), ["optional"], "Completed cleanup retains the future choice")
        _ = await second.perform(try action(second))
        XCTAssertEqual(calls.all, ["auto:optional", "manual:optional"])
        XCTAssertEqual(second.checked(try XCTUnwrap(second.activeSelection)), ["optional"])
        handleToggle("optional", second)
        XCTAssertNil(ActionDock(handle: second, isVisible: .constant(false)).phase)
        let nothing = await second.autoClean()
        XCTAssertNil(nothing)
        XCTAssertEqual(calls.all.count, 2)
    }
    private func handleToggle(_ id: String, _ handle: ModuleHandle) {
        guard let group = handle.activeSelection else { return XCTFail("Missing choices") }
        handle.toggle(id, in: group)
    }
    func testGraphCopiesShareChoicesAndUnavailableRowsDoNotEraseSavedIntent() async throws {
        let settings = SettingsStore(defaults: Fixtures.defaults()), calls = Calls()
        let handle = try await handle(settings, calls); defer { handle.deactivate() }
        handleToggle("optional", handle)
        handle.pushGroup("segment:all")
        XCTAssertEqual(handle.checked(try XCTUnwrap(handle.activeSelection)), ["safe", "optional"])
        handleToggle("safe", handle)
        handle.popGroup()
        XCTAssertEqual(handle.checked(try XCTUnwrap(handle.activeSelection)), ["optional"])
        settings.saveCleanupChoices(module: handle.id, scope: "cleanup", visible: ["safe"], selected: [])
        XCTAssertEqual(settings.cleanupChoices(module: handle.id)[CleanupTarget.preferenceKey(id: "optional")], true)
        XCTAssertTrue(calls.all.isEmpty)
    }
    func testChangedOperationsRejectTheFrozenConfirmationBeforeExecutingAnything() async throws {
        let settings = SettingsStore(defaults: Fixtures.defaults()), calls = Calls()
        let handle = try await handle(settings, calls); defer { handle.deactivate() }
        let frozen = try action(handle)
        settings.setOption(.bool(false), "flag", module: handle.id)
        await handle.refresh(quiet: true)
        let result = await handle.perform(frozen)
        XCTAssertEqual(result?.outcome, .failed)
        XCTAssertTrue(calls.all.isEmpty)
    }
    func testPersistedManualGroupDoesNotBecomeAutomaticCleanup() async throws {
        let defaults = Fixtures.defaults(), settings = SettingsStore(defaults: defaults)
        settings.saveCleanupChoices(module: "test", scope: "backups:disk", visible: ["old", "latest"], selected: ["old"])
        let fresh = SettingsStore(defaults: defaults).cleanupChoices(module: "test")
        XCTAssertEqual(fresh[CleanupTarget.preferenceKey(scope: "backups:disk", id: "old")], true)
        XCTAssertEqual(fresh[CleanupTarget.preferenceKey(scope: "backups:disk", id: "latest")], false)
        XCTAssertNil(fresh[CleanupTarget.preferenceKey(id: "old")], "Manual identities and renewable cleanup operations have separate preference scopes")
    }
}
