import XCTest
import MacSpaceSdk
@testable import MacSpaceApp

private struct CleanupSelectionModule: MacSpaceModule {
    let calls: Calls
    init() { calls = Calls() }
    init(calls: Calls) { self.calls = calls }
    func tile(context: ModuleContext) async -> Tile { Tile(title: "Cleanup", status: "") }
    func screen(context: ModuleContext) async -> Screen {
        let optedIn = context.options.bool(CleanupBatch.nonRecoverableOptionID)
        let rows = ["safe", "optional", "irreversible"].map { id in
            Row(id: id, title: id).selectingCleanup(Action(id: "clean", title: "Free", parameters: ["id": id, "variant": context.options.bool("flag") ? "one" : "two"],
                confirmation: Confirmation(title: "Free " + id + "?", message: "Details for " + id, confirmTitle: "Free")),
                bytes: 100, automatic: id != "irreversible" || optedIn,
                defaultSelected: id == "safe" || (id == "irreversible" && optedIn), remembersSelection: id != "irreversible")
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
        manifest.options.append(OptionDefinition(id: CleanupBatch.nonRecoverableOptionID, title: "Non recoverable", kind: .toggle(defaultValue: false)))
        try Fixtures.writeBundle(manifest, name: "Cleanup", into: directory)
        let descriptor = try XCTUnwrap(ModuleScanner.scan(directory: directory).modules.first)
        let handle = ModuleHandle(confirm: { _ in true }, descriptor: descriptor, settings: settings, permissions: FakePermissions(), loader: { _ in CleanupSelectionModule(calls: calls) })
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
        XCTAssertEqual(try action(first).confirmation?.message, "Details for optional")
        handleToggle("safe", first)
        XCTAssertEqual(try action(first).confirmation?.message, "Save your work first. Some changes may be permanent.")
        handleToggle("safe", first)
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

    func testBackupReviewIgnoresOldPreferencesAndClearsChoicesWhenLeavingTheModule() async throws {
        let settings = SettingsStore(defaults: Fixtures.defaults())
        let handle = try await handle(settings, Calls())
        defer { handle.deactivate() }
        settings.saveCleanupChoices(module: handle.id, scope: "backups:disk", visible: ["backup:old"], selected: ["backup:old"])
        let page = Screen(title: "Backups", widgets: [], selection: Selection(action: Action(id: "deleteBackups", title: "Free"),
            choices: ["backup:old": 0], scope: "backups:disk"))
        let first = try XCTUnwrap(handle.pageSelection(page, id: "backups"))
        XCTAssertTrue(handle.checked(first).isEmpty)
        handle.toggle("backup:old", in: first)
        XCTAssertEqual(handle.checked(first), ["backup:old"])
        handle.clearPageSelections()
        XCTAssertTrue(handle.checked(try XCTUnwrap(handle.pageSelection(page, id: "backups"))).isEmpty)
    }

    func testNonRecoverableChoicesIgnoreSavedConsentAndResetAfterCompletionAndEachVisit() async throws {
        let defaults = Fixtures.defaults(), settings = SettingsStore(defaults: defaults), calls = Calls()
        settings.saveCleanupChoices(module: "com.test.fake", scope: "cleanup", visible: ["irreversible"], selected: ["irreversible"])
        let first = try await handle(settings, calls)
        defer { first.deactivate() }
        XCTAssertEqual(first.checked(try XCTUnwrap(first.activeSelection)), ["safe"])
        handleToggle("irreversible", first)
        XCTAssertEqual(first.checked(try XCTUnwrap(first.activeSelection)), ["safe", "irreversible"])
        _ = await first.autoClean()
        XCTAssertEqual(calls.all, ["auto:safe"], "A manual checkbox never grants scheduled destructive cleanup")
        _ = await first.perform(try action(first))
        XCTAssertTrue(calls.all.contains("manual:irreversible"))
        XCTAssertEqual(first.checked(try XCTUnwrap(first.activeSelection)), ["safe"], "Completed destructive work requires a new selection")
        handleToggle("irreversible", first)
        first.clearPageSelections()
        XCTAssertEqual(first.checked(try XCTUnwrap(first.activeSelection)), ["safe"])
        let fresh = try await handle(SettingsStore(defaults: defaults), Calls())
        defer { fresh.deactivate() }
        XCTAssertEqual(fresh.checked(try XCTUnwrap(fresh.activeSelection)), ["safe"])
    }

    func testOptInSelectsNonRecoverableItemsAndTransientEditsDoNotOverrideTheSetting() async throws {
        let settings = SettingsStore(defaults: Fixtures.defaults()), calls = Calls()
        settings.saveCleanupChoices(module: "com.test.fake", scope: "cleanup", visible: ["irreversible"], selected: [])
        settings.setOption(.bool(true), CleanupBatch.nonRecoverableOptionID, module: "com.test.fake")
        let handle = try await handle(settings, calls)
        defer { handle.deactivate() }
        XCTAssertEqual(handle.checked(try XCTUnwrap(handle.activeSelection)), ["safe", "irreversible"])
        handleToggle("irreversible", handle)
        XCTAssertEqual(handle.checked(try XCTUnwrap(handle.activeSelection)), ["safe"])
        handle.clearPageSelections()
        XCTAssertEqual(handle.checked(try XCTUnwrap(handle.activeSelection)), ["safe", "irreversible"])
        _ = await handle.autoClean()
        XCTAssertEqual(calls.all, ["auto:safe", "auto:irreversible"])
        settings.setOption(.bool(false), CleanupBatch.nonRecoverableOptionID, module: handle.id)
        await handle.refresh(quiet: true)
        XCTAssertEqual(handle.checked(try XCTUnwrap(handle.activeSelection)), ["safe"])
        _ = await handle.autoClean()
        XCTAssertEqual(calls.all, ["auto:safe", "auto:irreversible", "auto:safe"])
        handleToggle("irreversible", handle)
        settings.setOption(.bool(true), CleanupBatch.nonRecoverableOptionID, module: handle.id)
        await handle.refresh(quiet: true)
        XCTAssertTrue(handle.checked(try XCTUnwrap(handle.activeSelection)).contains("irreversible"))
        settings.setOption(.bool(false), CleanupBatch.nonRecoverableOptionID, module: handle.id)
        await handle.refresh(quiet: true)
        XCTAssertFalse(handle.checked(try XCTUnwrap(handle.activeSelection)).contains("irreversible"), "A mode change retires the earlier visit override")
    }
}
