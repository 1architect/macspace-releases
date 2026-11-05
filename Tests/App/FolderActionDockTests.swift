import XCTest
import SwiftUI
import MacSpaceSdk
@testable import MacSpaceApp

private struct FolderActionModule: MacSpaceModule {
    init() {}
    func tile(context: ModuleContext) async -> Tile { Tile(title: "Files", status: "Ready") }
    func screen(context: ModuleContext) async -> Screen {
        Screen(title: "Files", primary: Action(id: "otherCleanup", title: "Other cleanup"), widgets: [
            .list(.init(id: "folders", rows: [Row(id: "folder", title: "Folder", pageID: "folder")]))
        ])
    }
    func page(id: String, context: ModuleContext) async -> Screen? {
        Screen(title: "Folder", hero: .init(id: "folder", title: "Folder", segments: []),
            widgets: [
                .list(.init(id: "files", rows: [Row(id: "file", title: "File")]))
            ], selection: Selection(action: Action(id: "reviewFiles", title: "Review selected files", pageID: "review"), choices: ["file": 1]))
    }
    func perform(_ request: ActionRequest, context: ModuleContext, progress: @escaping ProgressSink) async -> ActionResult { .succeeded("") }
}

@MainActor
final class FolderActionDockTests: XCTestCase {
    func testFolderHasNoDefaultActionAndOnlySelectedFilesShowReview() async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Fixtures.writeBundle(Fixtures.manifest(), name: "Folder", into: directory)
        let descriptor = try XCTUnwrap(ModuleScanner.scan(directory: directory).modules.first)
        let handle = ModuleHandle(descriptor: descriptor, settings: SettingsStore(defaults: Fixtures.defaults()),
            permissions: FakePermissions(), loader: { _ in FolderActionModule() })
        await handle.activate()
        defer { handle.deactivate() }
        handle.pushGroup("folder")
        for _ in 0..<100 where handle.pages["folder"] == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNil(ActionDock(handle: handle, isVisible: .constant(false)).phase)
        let selection = try XCTUnwrap(handle.activeSelection)
        handle.toggle("file", in: selection)
        guard case let .idle(selected)? = ActionDock(handle: handle, isVisible: .constant(false)).phase else {
            return XCTFail("Selecting a file must show its selection action")
        }
        XCTAssertEqual(selected.id, "reviewFiles")
        handle.toggle("file", in: try XCTUnwrap(handle.activeSelection))
        XCTAssertNil(ActionDock(handle: handle, isVisible: .constant(false)).phase)
    }
}
