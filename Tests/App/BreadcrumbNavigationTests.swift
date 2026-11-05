import XCTest
import MacSpaceSdk
@testable import MacSpaceApp

private struct BreadcrumbModule: MacSpaceModule {
    func tile(context: ModuleContext) async -> Tile { Tile(title: "Folders", status: "") }
    func screen(context: ModuleContext) async -> Screen {
        Screen(title: "Root", widgets: [.list(.init(id: "folders", rows: [Row(id: "first", title: "First", pageID: "first")]))])
    }
    func page(id: String, context: ModuleContext) async -> Screen? {
        if id == "slow" { try? await Task.sleep(for: .milliseconds(150)) }
        return Screen(title: id, widgets: [.list(.init(id: "folders", rows: [Row(id: "second", title: "Second", pageID: "second"), Row(id: "slow", title: "Slow", pageID: "slow")]))])
    }
    func perform(_ request: ActionRequest, context: ModuleContext, progress: @escaping ProgressSink) async -> ActionResult { .succeeded("") }
}

@MainActor
final class BreadcrumbNavigationTests: XCTestCase {
    func testAncestorJumpKeepsTheAncestorAndCancelsPendingChildNavigation() async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Fixtures.writeBundle(Fixtures.manifest(), name: "Navigation", into: directory)
        let descriptor = try XCTUnwrap(ModuleScanner.scan(directory: directory).modules.first)
        let handle = ModuleHandle(descriptor: descriptor, settings: SettingsStore(defaults: Fixtures.defaults()), permissions: FakePermissions(), loader: { _ in BreadcrumbModule() })
        await handle.activate(); defer { handle.deactivate() }
        handle.pushGroup("first")
        for _ in 0..<100 where handle.groupPath.count < 1 { try await Task.sleep(for: .milliseconds(5)) }
        handle.pushGroup("second")
        for _ in 0..<100 where handle.groupPath.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(handle.groupPath, ["first", "second"])
        handle.navigateToAncestor(depth: 1)
        XCTAssertEqual(handle.groupPath, ["first"])
        XCTAssertEqual(handle.pages["first"]?.title, "first")
        handle.pushGroup("slow")
        handle.navigateToAncestor(depth: 0)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(handle.groupPath.isEmpty, "A pending child must not reopen after clicking the root breadcrumb")
        handle.navigateToAncestor(depth: -1)
        XCTAssertTrue(handle.groupPath.isEmpty)
    }
}
