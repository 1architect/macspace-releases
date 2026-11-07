import Foundation
import XCTest
import MacSpaceSdk

private struct CleanupOptions: OptionStore {
    func bool(_ id: String) -> Bool { false }
    func string(_ id: String) -> String { "" }
    func isBackgroundTaskEnabled(_ id: String) -> Bool { false }
}
private struct CleanupPermissions: PermissionChecker {
    var allowed = true
    func status(of permission: Permission) -> PermissionStatus { allowed ? .granted : .missing }
}
private actor CleanupCalls {
    var requests: [ActionRequest] = []
    func perform(_ request: ActionRequest, context: ModuleContext, progress: @escaping ProgressSink) async -> ActionResult {
        requests.append(request)
        return .init(outcome: request.actionID == "fail" ? .failed : .succeeded, message: "Fixture", refresh: false, freedBytes: request.actionID == "fail" ? nil : 10)
    }
}
final class CleanupContractTests: XCTestCase {
    private func context(allowed: Bool = true, choices: [String: Bool] = [:]) -> ModuleContext {
        ModuleContext(manifest: ModuleManifest(id: "test", name: "Test", summary: "", version: "test", symbol: "star"), options: CleanupOptions(), permissions: CleanupPermissions(allowed: allowed), cleanupChoices: choices)
    }
    func testAutomaticRunUsesCurrentAvailabilityAndSavedChoicesWithoutSelectingNewRows() async {
        let calls = CleanupCalls()
        var busy = Row(id: "busy", title: "Busy"); busy.activity = .init(fraction: 0.5, message: "Removing")
        let rows = [Row(id: "selected", title: "Selected").selectingCleanup(Action(id: "clean", title: "Free"), bytes: 10),
                    Row(id: "new", title: "New").selectingCleanup(Action(id: "cleanNew", title: "Free"), bytes: 10),
                    Row(id: "off", title: "Off").selectingCleanup(Action(id: "cleanOff", title: "Free"), bytes: 10, defaultSelected: true),
                    busy.selectingCleanup(Action(id: "cleanBusy", title: "Free"), bytes: 10, defaultSelected: true),
                    Row(id: "manual", title: "Manual").selectingCleanup(Action(id: "manual", title: "Free"), bytes: 10, automatic: false, defaultSelected: true)]
        let page = Screen(title: "Test", widgets: [.list(ListWidget(id: "rows", rows: rows))])
        let ctx = context(choices: [CleanupTarget.preferenceKey(id: "selected"): true, CleanupTarget.preferenceKey(id: "off"): false])
        let result = await CleanupBatch.automatic(screen: page, context: ctx, perform: calls.perform)
        XCTAssertEqual(result?.freedBytes, 10)
        let requests = await calls.requests
        XCTAssertEqual(requests.map(\.actionID), ["clean"])
        XCTAssertEqual(requests.first?.parameters["automatic"], "1")
    }
    func testMissingPermissionsAndDuplicateTargetsRejectManualBatchBeforeMutation() async {
        let calls = CleanupCalls()
        let target = CleanupTarget(id: "one", title: "One", bytes: 10, action: Action(id: "clean", title: "Free", requires: [.privilegedHelper]))
        let denied = await CleanupBatch.run([target], automatic: false, context: context(allowed: false), progress: { _ in }, perform: calls.perform)
        XCTAssertEqual(denied.outcome, .failed)
        let duplicate = await CleanupBatch.run([target, target], automatic: false, context: context(), progress: { _ in }, perform: calls.perform)
        XCTAssertEqual(duplicate.outcome, .failed)
        let requests = await calls.requests
        XCTAssertTrue(requests.isEmpty)
    }
    func testBatchReportsPartialFailureAndOnlyMeasuresCompletedActions() async {
        let calls = CleanupCalls()
        let targets = [CleanupTarget(id: "one", title: "One", bytes: 10, action: Action(id: "clean", title: "Free")),
                       CleanupTarget(id: "two", title: "Two", bytes: 10, action: Action(id: "fail", title: "Free"))]
        let result = await CleanupBatch.run(targets, automatic: false, context: context(), progress: { _ in }, perform: calls.perform)
        XCTAssertEqual(result.outcome, .needsAttention)
        XCTAssertEqual(result.freedBytes, 10)
    }
    func testCleanupMetadataAndPersistenceRoundTripAndOldRowsRemainCompatible() throws {
        let row = Row(id: "choice", title: "Choice").selectingCleanup(Action(id: "clean", title: "Free"), bytes: 123)
        XCTAssertTrue(row.actions.isEmpty)
        XCTAssertEqual(try JSONDecoder().decode(Row.self, from: JSONEncoder().encode(row)), row)
        let old = Data(#"{"id":"old","title":"Old"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(Row.self, from: old).cleanup)
        let selection = Selection(action: Action(id: "clean", title: "Free"), choices: ["choice": 123], persistenceKey: "cleanup")
        XCTAssertEqual(try JSONDecoder().decode(Selection.self, from: JSONEncoder().encode(selection)), selection)
        XCTAssertNotEqual(CleanupTarget.preferenceKey(scope: "a:b", id: "c"), CleanupTarget.preferenceKey(scope: "a", id: "b:c"))
    }

    func testTransientCleanupPolicyRoundTripsAndIgnoresOldCheckboxPreferences() throws {
        var target = CleanupTarget(id: "trash", title: "Trash", bytes: 1, action: Action(id: "emptyTrash", title: "Free"),
            automatic: false, remembersSelection: false)
        let saved = [CleanupTarget.preferenceKey(id: target.id): true]
        XCTAssertFalse(target.isSelected(saved))
        XCTAssertEqual(try JSONDecoder().decode(CleanupTarget.self, from: JSONEncoder().encode(target)), target)
        target.defaultSelected = true; target.automatic = true
        XCTAssertTrue(target.isSelected([CleanupTarget.preferenceKey(id: target.id): false]))
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(target)) as? [String: Any])
        legacy.removeValue(forKey: "remembersSelection")
        XCTAssertTrue(try JSONDecoder().decode(CleanupTarget.self, from: JSONSerialization.data(withJSONObject: legacy)).remembersSelection)
    }
}

extension CleanupContractTests {
    func testBackgroundHandoffKeepsItsProgressRowAndDoesNotClaimCompletion() async {
        let action = Action(id: "cloud", title: "Free", parameters: ["path": "/fixture/cloud"])
        let target = CleanupTarget(id: "cloud-row", title: "Cloud", bytes: 100, action: action)
        var row = Row(id: target.id, title: target.title)
        row.activity = .init(fraction: 0.2, message: "Removing downloads")
        row = row.selectingCleanup(action, bytes: 100)
        let presentation = ModulePresentation(tile: Tile(title: "Cloud", status: "Removing"), screen: Screen(title: "Cloud", widgets: [.list(ListWidget(id: "cloud", rows: [row]))]))
        let result = await CleanupBatch.run([target], automatic: false, context: context(), progress: { _ in }) { _, _, _ in
            ActionResult(outcome: .succeeded, message: "", freedBytes: 0, presentation: presentation)
        }
        XCTAssertEqual(result.outcome, .succeeded)
        XCTAssertTrue(result.message.isEmpty)
        XCTAssertTrue(result.presentation?.screen.activeCleanupRow(for: .init(actionID: action.id, parameters: action.parameters)) == true)
        XCTAssertEqual(result.presentation?.screen.cleanupTargets.first?.available, false)
    }
}
