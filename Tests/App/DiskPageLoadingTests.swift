import Foundation
import XCTest
import MacSpaceSdk
@testable import MacSpaceApp

private actor PageReadControl {
    private var continuation: CheckedContinuation<Void, Never>?
    private var reports: LoadProgressSink?
    private(set) var requested = false
    private(set) var roots = 0
    private(set) var pages = 0
    func root() { roots += 1 }
    func page(_ progress: @escaping LoadProgressSink) async {
        pages += 1
        if pages == 1 {
            requested = true; reports = progress
            await withCheckedContinuation { continuation = $0 }
        }
    }
    func advance(_ fraction: Double) { reports?(fraction) }
    func finish() { continuation?.resume(); continuation = nil }
}
private struct CachedDiskPageModule: MacSpaceModule {
    let control: PageReadControl
    init() { control = PageReadControl() }
    init(_ control: PageReadControl) { self.control = control }
    func tile(context: ModuleContext) async -> Tile { Tile(title: "Disk", status: "Ready") }
    func screen(context: ModuleContext) async -> Screen {
        await control.root()
        return Screen(title: "Disk", widgets: [.list(.init(id: "nav", rows: [.init(id: "folder", title: "Folder", pageID: "folder")]))])
    }
    func page(id: String, context: ModuleContext, progress: @escaping LoadProgressSink) async -> Screen? {
        await control.page(progress)
        return Screen(title: "Folder", widgets: [.list(.init(id: "files", rows: [.init(id: "one", title: "One")]))], loadingFraction: 0.5)
    }
    func page(id: String, context: ModuleContext) async -> Screen? { await page(id: id, context: context, progress: { _ in }) }
    func perform(_ request: ActionRequest, context: ModuleContext, progress: @escaping ProgressSink) async -> ActionResult { .failed("Fixture") }
}
@MainActor
final class DiskPageLoadingTests: XCTestCase {
    private func handle(_ control: PageReadControl, directory: URL) async throws -> ModuleHandle {
        try Fixtures.writeBundle(Fixtures.manifest(), name: "Test", into: directory)
        let descriptor = try XCTUnwrap(ModuleScanner.scan(directory: directory).modules.first)
        let handle = ModuleHandle(confirm: { _ in true }, descriptor: descriptor, settings: SettingsStore(defaults: Fixtures.defaults()), permissions: FakePermissions(), loader: { _ in CachedDiskPageModule(control) })
        await handle.activate()
        return handle
    }
    func testPageTransitionDoesNotInventLoadingAndLateReportsCannotRestoreIt() async throws {
        let directory = try Fixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let control = PageReadControl(), handle = try await handle(control, directory: directory)
        defer { handle.deactivate() }
        handle.pushGroup("folder")
        XCTAssertTrue(handle.groupPath.isEmpty, "The default page transition waits for its destination rows to be ready")
        XCTAssertNil(handle.pages["folder"], "Never animate an empty destination then insert rows halfway through")
        for _ in 0..<100 { if await control.requested { break }; await Task.yield() }
        XCTAssertNil(handle.pageLoading); XCTAssertFalse(handle.isBusy)
        await control.finish()
        for _ in 0..<100 where handle.pages["folder"]?.loadingFraction == nil { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertEqual(handle.groupPath, ["folder"])
        guard case let .list(list)? = handle.pages["folder"]?.widgets.first else { return XCTFail("Destination rows must exist when navigation starts") }
        XCTAssertEqual(list.rows.map(\.id), ["one"])
        XCTAssertNil(handle.pageLoading)
        await control.advance(0)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(handle.pageLoading, "Completed navigation must reject late zero-percent reports")
        let roots = await control.roots
        await handle.followPendingPage()
        let after = await control.roots
        XCTAssertEqual(after, roots, "Pending page completion must not trigger an unrelated global disk scan")
        XCTAssertNil(handle.pageLoading)
    }
    func testRealPageWorkCanReportProgressAndCompletionClearsIt() async throws {
        let directory = try Fixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let control = PageReadControl(), handle = try await handle(control, directory: directory)
        defer { handle.deactivate() }
        handle.pushGroup("folder")
        XCTAssertTrue(handle.groupPath.isEmpty, "The default page transition waits for its destination rows to be ready")
        XCTAssertNil(handle.pages["folder"], "Never animate an empty destination then insert rows halfway through")
        for _ in 0..<100 { if await control.requested { break }; await Task.yield() }
        await control.advance(0.4)
        for _ in 0..<100 where handle.pageLoading?.reported != 0.4 { await Task.yield() }
        XCTAssertEqual(handle.pageLoading?.reported, 0.4)
        await control.finish()
        for _ in 0..<100 where handle.pages["folder"]?.loadingFraction == nil { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertNil(handle.pageLoading); XCTAssertFalse(handle.isBusy)
    }
}
