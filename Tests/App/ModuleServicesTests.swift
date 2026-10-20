import XCTest
import MacSpaceSdk
@testable import MacSpaceApp

private final class Opened: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [URL] = []
    var all: [URL] { lock.withLock { stored } }
    func add(_ url: URL) { lock.withLock { stored.append(url) } }
}

/// What the app does for every module (`ModuleServices`, `Action.openSettings`): the module is never called for it.
@MainActor
final class ModuleServicesTests: XCTestCase {
    private func handle(calls: Calls, opened: Opened, directory: URL) throws -> ModuleHandle {
        try Fixtures.writeBundle(Fixtures.manifest(), name: "Test", into: directory)
        let descriptor = try XCTUnwrap(ModuleScanner.scan(directory: directory).modules.first)
        return ModuleHandle(descriptor: descriptor, settings: SettingsStore(defaults: Fixtures.defaults()), permissions: FakePermissions(),
                            loader: { _ in FakeModule(calls: calls) }, openPane: { opened.add($0) })
    }

    func testTheAppOpensSystemSettingsPanesAndNothingElse() async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let calls = Calls(), opened = Opened()
        let handle = try handle(calls: calls, opened: opened, directory: directory)
        await handle.activate()
        defer { handle.deactivate() }
        let pane = try XCTUnwrap(URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension"))
        await handle.perform(.openSettings(title: "Open", url: pane), rowID: "update")
        await handle.perform(Action(id: Action.openSettingsID, title: "Open", parameters: ["url": "https://example.com"]))
        await handle.perform(.allowFullDiskAccess(title: "Allow"))
        XCTAssertEqual(opened.all.count, 2, "not the web page")
        XCTAssertEqual(opened.all.first, pane)
        XCTAssertEqual(opened.all.last?.absoluteString.contains("Privacy_AllFiles"), true, "Full Disk Access")
        XCTAssertTrue(calls.all.isEmpty, "the module is not called")
        XCTAssertNil(handle.rowResult)
        XCTAssertEqual(handle.allDone, 0, "opening System Settings is not All done")

        // What a module opens by itself goes through the same check.
        let services = handle.context().services
        services.openSettings(try XCTUnwrap(URL(string: "file:///Applications")))
        services.openSettings(pane)
        XCTAssertEqual(opened.all.last, pane)
        XCTAssertEqual(opened.all.count, 3)
    }

    /// A module's notification carries its id, so a click opens its page; each one stays in its own group.
    func testModuleNotificationsOpenTheirPage() {
        let content = AppNotifications.moduleContent(module: "com.macspace.debloat", title: "T", body: "B")
        XCTAssertEqual(AppNotifications.destination(content.userInfo), .module("com.macspace.debloat"))
        XCTAssertEqual(content.threadIdentifier, "com.macspace.debloat")
        XCTAssertEqual(content.title, "T")
        XCTAssertEqual(content.body, "B")
    }
}
