import XCTest
import MacSpaceSdk
@testable import MacSpaceApp

private struct FileReviewNavigationModule: MacSpaceModule {
    let calls: Calls
    init() { calls = Calls() }
    init(calls: Calls) { self.calls = calls }
    var picker: Selection {
        Selection(action: Action(id: "reviewFiles", title: "Review selected files", pageID: "file-review"),
            choices: ["one": 100, "two": 200], scope: "disk-files", partial: true, session: true,
            reviewed: ["one": "first-identity", "two": "second-identity"])
    }
    func tile(context: ModuleContext) async -> Tile { Tile(title: "Files", status: "") }
    func screen(context: ModuleContext) async -> Screen {
        Screen(title: "Files", widgets: [.list(ListWidget(id: "files", rows: [Row(id: "one", title: "One"), Row(id: "two", title: "Two")]))], selection: picker)
    }
    func page(id: String, context: ModuleContext) async -> Screen? {
        guard let request = ActionPageRequest(pageID: id), request.destination == "file-review" else { return nil }
        calls.add("review:" + (request.parameters["ids"] ?? ""))
        var page = await screen(context: context)
        page.title = "Review selected files"
        page.selection?.action = Action(id: "freeFiles", title: "Delete", role: .destructive,
            confirmation: Confirmation(title: "Delete?", message: "Selected files", confirmTitle: "Delete"))
        return page
    }
    func perform(_ request: ActionRequest, context: ModuleContext, progress: @escaping ProgressSink) async -> ActionResult {
        calls.add("perform:" + request.actionID + ":" + (request.parameters["ids"] ?? ""))
        return ActionResult(outcome: .succeeded, message: "Deleted", refresh: false)
    }
}

@MainActor
final class FileReviewNavigationTests: XCTestCase {
    func testReviewNavigatesWithFrozenChoicesAndOnlyTheFinalActionExecutes() async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Fixtures.writeBundle(Fixtures.manifest(), name: "Files", into: directory)
        let descriptor = try XCTUnwrap(ModuleScanner.scan(directory: directory).modules.first)
        let calls = Calls()
        let handle = ModuleHandle(confirm: { _ in true }, descriptor: descriptor, settings: SettingsStore(defaults: Fixtures.defaults()),
            permissions: FakePermissions(), loader: { _ in FileReviewNavigationModule(calls: calls) })
        await handle.activate(); defer { handle.deactivate() }
        func action() throws -> Action {
            guard case let .idle(value)? = ActionDock(handle: handle, isVisible: .constant(false)).phase else {
                throw NSError(domain: "Missing file review action", code: 1)
            }
            return value
        }
        let picker = try XCTUnwrap(handle.activeSelection)
        handle.toggle("one", in: picker)
        handle.toggle("two", in: try XCTUnwrap(handle.activeSelection))
        let review = try action()
        XCTAssertEqual(review.pageID, "file-review")
        XCTAssertNil(review.confirmation)
        XCTAssertEqual(Set(Selection.ids(review.parameters["ids"])), ["one", "two"])
        XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: Data(try XCTUnwrap(review.parameters["reviewed"]).utf8)),
            ["one": "first-identity", "two": "second-identity"])
        _ = await handle.perform(review)
        for _ in 0..<100 where handle.groupPath.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(handle.groupPath.count, 1)
        XCTAssertEqual(calls.all.count, 1)
        XCTAssertTrue(calls.all.first?.hasPrefix("review:") == true)
        XCTAssertEqual(try action().id, "freeFiles")
        XCTAssertNil(try action().pageID)
        XCTAssertNotNil(try action().confirmation)
        handle.toggle("one", in: try XCTUnwrap(handle.activeSelection))
        XCTAssertEqual(Selection.ids(try action().parameters["ids"]), ["two"])
        _ = await handle.perform(try action())
        XCTAssertEqual(calls.all.last, "perform:freeFiles:" + Selection.parameter(["two"]))
    }
}
