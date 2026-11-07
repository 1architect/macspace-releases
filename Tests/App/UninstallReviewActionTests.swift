import XCTest
import MacSpaceSdk
import MacSpacePlatform
@testable import MacSpaceApp

private struct ReviewActionModule: MacSpaceModule {
    func tile(context: ModuleContext) async -> Tile { Tile(title: "Apps", status: "") }
    func screen(context: ModuleContext) async -> Screen {
        let action = Action(id: "uninstallSelected", title: "Uninstall", parameters: ["plans": "frozen"])
        return Screen(title: "Review", primary: action, widgets: [.list(.init(id: "data", rows: [Row(id: "data", title: "App data")]))],
            selection: Selection(action: action, choices: ["data": 50_000_000], scope: "review", includedBytes: 100_000_000))
    }
    func perform(_ request: ActionRequest, context: ModuleContext, progress: @escaping ProgressSink) async -> ActionResult { .succeeded("") }
}

@MainActor
final class UninstallReviewActionTests: XCTestCase {
    func testMandatoryAppsAndOptionalDataAlwaysContributeToTheSameActionTotal() async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Fixtures.writeBundle(Fixtures.manifest(), name: "Review", into: directory)
        let descriptor = try XCTUnwrap(ModuleScanner.scan(directory: directory).modules.first)
        let handle = ModuleHandle(confirm: { _ in true }, descriptor: descriptor, settings: SettingsStore(defaults: Fixtures.defaults()), permissions: FakePermissions(), loader: { _ in ReviewActionModule() })
        await handle.activate(); defer { handle.deactivate() }
        func action() throws -> Action {
            guard case let .idle(action)? = ActionDock(handle: handle, isVisible: .constant(false)).phase else {
                throw NSError(domain: "Missing uninstall action", code: 1)
            }
            return action
        }
        XCTAssertEqual(try action().title, "Uninstall " + ByteFormat.string(100_000_000))
        XCTAssertEqual(try action().parameters["plans"], "frozen")
        let group = try XCTUnwrap(handle.activeSelection)
        handle.toggle("data", in: group)
        XCTAssertEqual(try action().title, "Uninstall " + ByteFormat.string(150_000_000))
        XCTAssertEqual(Selection.ids(try action().parameters["ids"]), ["data"])
        handle.toggle("data", in: group)
        XCTAssertEqual(try action().title, "Uninstall " + ByteFormat.string(100_000_000))
        XCTAssertTrue(Selection.ids(try action().parameters["ids"]).isEmpty)
    }
}
