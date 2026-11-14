import XCTest
import MacSpaceSdk
@testable import MacSpaceApp

private actor JointReads {
    var events: [String] = []
    func record(_ value: String) { events.append(value) }
}

private struct JointModule: MacSpaceModule, ModulePresentationReading {
    let reads: JointReads
    init() { reads = JointReads() }
    init(_ reads: JointReads) { self.reads = reads }
    func tile(context: ModuleContext) async -> Tile {
        await reads.record("tile")
        return Tile(title: "Tile", status: "ready")
    }
    func screen(context: ModuleContext) async -> Screen {
        await reads.record("screen")
        return Screen(title: "Page", widgets: [])
    }
    func presentation(context: ModuleContext, progress: @escaping LoadProgressSink) async -> ModulePresentation {
        await reads.record("presentation")
        progress(0.25)
        return ModulePresentation(tile: Tile(title: "Tile", status: "ready"), screen: Screen(title: "Page", widgets: []))
    }
    func perform(_ request: ActionRequest, context: ModuleContext, progress: @escaping ProgressSink) async -> ActionResult { .succeeded("") }
}

@MainActor
final class JointPresentationTests: XCTestCase {
    private func make(_ directory: URL, reads: JointReads, screen: Bool) throws -> ModuleHandle {
        try Fixtures.writeBundle(Fixtures.manifest(), name: "Joint", into: directory)
        let descriptor = try XCTUnwrap(ModuleScanner.scan(directory: directory).modules.first)
        let handle = ModuleHandle(descriptor: descriptor, settings: SettingsStore(defaults: Fixtures.defaults()),
                                  permissions: FakePermissions(), loader: { _ in JointModule(reads) })
        handle.setWatched(true, screenVisible: screen)
        return handle
    }

    func testPageAndTileUseOnePresentationRequest() async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reads = JointReads(), handle = try make(directory, reads: reads, screen: true)
        defer { handle.deactivate() }
        await handle.activate()
        let events = await reads.events
        XCTAssertEqual(events, ["presentation"])
        XCTAssertEqual(handle.tile?.title, "Tile")
        XCTAssertEqual(handle.screen?.title, "Page")
        XCTAssertFalse(handle.isBusy)
    }

    func testDashboardDoesNotBuildAnUnusedPageAndOpeningItUsesTheJointRead() async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reads = JointReads(), handle = try make(directory, reads: reads, screen: false)
        defer { handle.deactivate() }
        await handle.activate()
        let dashboard = await reads.events
        XCTAssertEqual(dashboard, ["tile"])
        XCTAssertNil(handle.screen)
        handle.setWatched(true, screenVisible: true)
        for _ in 0..<100 where handle.screen == nil { try await Task.sleep(for: .milliseconds(2)) }
        let opened = await reads.events
        XCTAssertEqual(opened, ["tile", "presentation"])
        XCTAssertEqual(handle.screen?.title, "Page")
    }

    func testExplicitRefreshStillRereadsBothSurfacesTogether() async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reads = JointReads(), handle = try make(directory, reads: reads, screen: true)
        defer { handle.deactivate() }
        await handle.activate()
        await handle.refresh(reload: true)
        let events = await reads.events
        XCTAssertEqual(events, ["presentation", "presentation"])
        XCTAssertEqual(handle.tile?.status, "ready")
    }
}
