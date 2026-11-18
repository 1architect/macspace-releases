import AppKit
import MacSpaceSdk
import SwiftUI
import XCTest
@testable import MacSpaceApp

private actor LazyPageModel {
    var bytes: UInt64 = 100
    var review: ActionPageRequest?
    func record(_ request: ActionPageRequest) { review = request }
    func remove() { bytes = 50 }
}
private struct LazyPageModule: MacSpaceModule {
    let model: LazyPageModel
    init() { model = LazyPageModel() }
    init(model: LazyPageModel) { self.model = model }
    func tile(context: ModuleContext) async -> Tile { Tile(title: "Disk", status: "Ready") }
    func screen(context: ModuleContext) async -> Screen {
        let row = Row(id: "apps-entry", title: "Apps", actions: [Action(id: "review", title: "Uninstall", pageID: "apps")], pageID: "apps")
        let selection = Selection(action: Action(id: "review", title: "Review", pageID: "selected-apps"),
            choices: ["app:A": 10, "app:B": 20, "app:C": 30],
            checked: ["app:B", "app:A"], reviewed: ["app:A": "identity A", "app:B": "identity B", "app:C": "identity C"])
        return Screen(title: "Disk", hero: UsageBar(id: "map", title: "", segments: [UsageSegment(id: "folder", label: "Folder", bytes: await model.bytes, tone: .series(0), pageID: "folder:A")]),
                      widgets: [.list(ListWidget(id: "apps", rows: [row]))], selection: selection)
    }
    func page(id: String, context: ModuleContext) async -> Screen? {
        if let request = ActionPageRequest(pageID: id) {
            await model.record(request)
            return Screen(title: "Review", widgets: [])
        }
        if id == "folder:A" { return Screen(title: "Folder", hero: UsageBar(id: "folder", title: "", segments: [UsageSegment(id: "file", label: "File", bytes: await model.bytes, tone: .series(0))]), widgets: [.list(ListWidget(id: "large", title: "Large files", rows: [Row(id: "file", title: "Large file", trailing: "100 MB", actions: [Action(id: "delete", title: "Delete")])]))]) }
        if id == "apps" { return Screen(title: "Apps", layout: .singleColumn, widgets: [.list(ListWidget(id: "apps", rows: [Row(id: "app", title: "Test App", trailing: "100 MB", actions: [Action(id: "uninstall", title: "Uninstall")], iconPath: "/System/Applications/Calculator.app")]))]) }
        return nil
    }
    func perform(_ request: ActionRequest, context: ModuleContext, progress: @escaping ProgressSink) async -> ActionResult {
        await model.remove()
        return ActionResult(outcome: .succeeded, message: "Removed", presentation: ModulePresentation(tile: await tile(context: context), screen: await screen(context: context)))
    }
}
@MainActor
final class LazyModulePageTests: XCTestCase {
    func testSelectionReviewNavigationCarriesFrozenIDsWithoutExecutingAnAction() async throws {
        let directory = try Fixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        try Fixtures.writeBundle(Fixtures.manifest(), name: "Test", into: directory)
        let descriptor = try XCTUnwrap(ModuleScanner.scan(directory: directory).modules.first)
        let model = LazyPageModel()
        let handle = ModuleHandle(confirm: { _ in true }, descriptor: descriptor, settings: SettingsStore(defaults: Fixtures.defaults()), permissions: FakePermissions(), loader: { _ in LazyPageModule(model: model) })
        await handle.activate(); defer { handle.deactivate() }
        let action = try XCTUnwrap(handle.selectedAction)
        let result = await handle.perform(action)
        XCTAssertNil(result)
        for _ in 0..<100 { if await model.review != nil { break }; try await Task.sleep(for: .milliseconds(5)) }
        let received = await model.review, bytes = await model.bytes
        let review = try XCTUnwrap(received)
        XCTAssertEqual(review.destination, "selected-apps")
        XCTAssertEqual(try Selection.decodeIDs(review.parameters["ids"]), ["app:A", "app:B"])
        let reviewed = try XCTUnwrap(review.parameters["reviewed"])
        XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: Data(reviewed.utf8)),
                       ["app:A": "identity A", "app:B": "identity B"])
        XCTAssertEqual(bytes, 100)
        XCTAssertFalse(handle.isCleaning)
    }
    func testReviewActionOpensPageWithoutCallingModuleMutation() async throws {
        let directory = try Fixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        try Fixtures.writeBundle(Fixtures.manifest(), name: "Test", into: directory)
        let descriptor = try XCTUnwrap(ModuleScanner.scan(directory: directory).modules.first)
        let model = LazyPageModel()
        let handle = ModuleHandle(confirm: { _ in true }, descriptor: descriptor, settings: SettingsStore(defaults: Fixtures.defaults()), permissions: FakePermissions(), loader: { _ in LazyPageModule(model: model) })
        await handle.activate(); defer { handle.deactivate() }
        let screen = try XCTUnwrap(handle.screen)
        let row = try XCTUnwrap(ScreenView.row("apps-entry", in: screen))
        let action = try XCTUnwrap(row.actions.first)
        XCTAssertTrue(ModuleHandle.opensAtOnce(action))
        let result = await handle.perform(action, rowID: row.id)
        XCTAssertNil(result)
        for _ in 0..<100 where handle.pages["apps"] == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(handle.groupPath, ["apps"])
        XCTAssertNil(handle.runningAction)
        XCTAssertTrue(handle.queuedRows.isEmpty)
        let bytes = await model.bytes
        XCTAssertEqual(bytes, 100, "Opening the review page never invokes perform")
    }
    func testLazyFolderAndAppsPagesUseBackAndReconcileAfterRowActions() async throws {
        let directory = try Fixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        try Fixtures.writeBundle(Fixtures.manifest(), name: "Test", into: directory)
        let descriptor = try XCTUnwrap(ModuleScanner.scan(directory: directory).modules.first)
        let model = LazyPageModel()
        let handle = ModuleHandle(confirm: { _ in true }, descriptor: descriptor, settings: SettingsStore(defaults: Fixtures.defaults()), permissions: FakePermissions(), loader: { _ in LazyPageModule(model: model) })
        await handle.activate(); defer { handle.deactivate() }
        handle.pushGroup("folder:A")
        for _ in 0..<100 where handle.groupPath.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(handle.groupPath, ["folder:A"])
        XCTAssertEqual(handle.navigationRow("folder:A")?.title, "Folder")
        XCTAssertEqual(handle.pages["folder:A"]?.hero?.segments.first?.bytes, 100)
        let view = NSHostingView(rootView: ScreenView(handle: handle, tint: .blue).frame(width: 1448, height: 730).foregroundStyle(.white).background(TileBackdrop(tint: .blue)))
        let window = NSWindow(contentRect: CGRect(x: -5000, y: 0, width: 1448, height: 730), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.orderBack(nil); defer { window.close() }
        try await Task.sleep(for: .seconds(1))
        if let path = ProcessInfo.processInfo.environment["MACSPACE_SNAPSHOT_DIR"], let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path).appendingPathComponent("disk-folder-page.png"))
        }
        _ = await handle.perform(Action(id: "delete", title: "Delete"), rowID: "file")
        XCTAssertEqual(handle.pages["folder:A"]?.hero?.segments.first?.bytes, 50)
        handle.popGroup(); XCTAssertTrue(handle.groupPath.isEmpty)
        handle.pushGroup("apps-entry")
        for _ in 0..<100 where handle.groupPath.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(handle.pages["apps-entry"]?.layout, .singleColumn)
        XCTAssertEqual(handle.groupPath, ["apps-entry"])
        try await Task.sleep(for: .seconds(1))
        if let path = ProcessInfo.processInfo.environment["MACSPACE_SNAPSHOT_DIR"], let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path).appendingPathComponent("disk-apps-page.png"))
        }
        handle.popGroup(); XCTAssertTrue(handle.groupPath.isEmpty)
        XCTAssertEqual(Destination.storage.moduleID, "com.macspace.disk-map")
        XCTAssertTrue(DashboardTile(destination: .storage, size: Bento.Size(width: 1, height: 1), tint: .rose).opens)
    }
}
