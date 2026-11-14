import XCTest
import MacSpaceSdk
@testable import MacSpaceApp

private final class ModuleLoadControl: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var reads = 0
    private var usedMainThread = false
    var count: Int { lock.withLock { reads } }
    var ranOnMain: Bool { lock.withLock { usedMainThread } }
    func load() -> any MacSpaceModule {
        lock.withLock { reads += 1; usedMainThread = usedMainThread || Thread.isMainThread }
        _ = gate.wait(timeout: .now() + 5)
        return FakeModule()
    }
    func release() { gate.signal() }
}

@MainActor
final class ModuleStartupTests: XCTestCase {
    private func handle(in directory: URL, loader: @escaping ModuleHandle.Loader) throws -> ModuleHandle {
        try Fixtures.writeBundle(Fixtures.manifest(), name: "Fixture", into: directory)
        let descriptor = try XCTUnwrap(ModuleScanner.scan(directory: directory).modules.first)
        let handle = ModuleHandle(descriptor: descriptor, settings: SettingsStore(defaults: Fixtures.defaults()),
                                  permissions: FakePermissions(), loader: loader)
        handle.setWatched(false)
        return handle
    }

    func testConcurrentActivationSharesBundleLoadAndLeavesMainActorAvailable() async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let control = ModuleLoadControl()
        defer { control.release() }
        let handle = try handle(in: directory, loader: { _ in control.load() })
        defer { handle.deactivate() }
        let tasks = (0..<12).map { _ in Task { await handle.activate() } }
        for _ in 0..<200 where control.count == 0 { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertEqual(control.count, 1)
        XCTAssertFalse(control.ranOnMain, "loading code must not stall the interface")
        XCTAssertEqual(handle.state, .off, "the main actor runs while the bundle is still loading")
        control.release()
        for task in tasks { await task.value }
        XCTAssertEqual(control.count, 1)
        XCTAssertEqual(handle.state, .ready)
    }

    func testDisablingDuringLoadDoesNotReactivateOrReadModule() async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let control = ModuleLoadControl()
        defer { control.release() }
        let handle = try handle(in: directory, loader: { _ in control.load() })
        defer { handle.deactivate() }
        let loading = Task { await handle.activate() }
        for _ in 0..<200 where control.count == 0 { try await Task.sleep(for: .milliseconds(2)) }
        handle.settings.setEnabled(false, module: handle.id)
        handle.deactivate()
        control.release()
        await loading.value
        XCTAssertEqual(handle.state, .off)
        XCTAssertNil(handle.tile)
        XCTAssertNil(handle.screen)
        handle.settings.setEnabled(true, module: handle.id)
        await handle.activate()
        XCTAssertEqual(handle.state, .ready)
        XCTAssertEqual(control.count, 1, "the already loaded bundle is reused when enabled again")
    }

    func testSynchronousSlowLoaderDoesNotHoldBackOtherModules() async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for (id, name) in [("com.test.slow", "A"), ("com.test.fast", "B")] {
            try Fixtures.writeBundle(Fixtures.manifest(id: id), name: name, into: directory)
        }
        let control = ModuleLoadControl()
        defer { control.release() }
        let host = ModuleHost(modulesDirectory: directory, settings: SettingsStore(defaults: Fixtures.defaults()),
                              permissions: FakePermissions(), privileged: nil,
                              loader: { $0.id == "com.test.slow" ? control.load() : FakeModule() })
        let loading = Task { await host.reload() }
        for _ in 0..<300 where host.handle(for: "com.test.fast")?.state != .ready {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(host.handle(for: "com.test.fast")?.state, .ready)
        XCTAssertEqual(host.handle(for: "com.test.slow")?.state, .off)
        control.release()
        await loading.value
        host.handles.forEach { $0.deactivate() }
        host.scheduler.stopAll()
    }

    func testUninstallJoinsPendingLoadWithoutConstructingAnotherModule() async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let control = ModuleLoadControl()
        defer { control.release() }
        let handle = try handle(in: directory, loader: { _ in control.load() })
        defer { handle.deactivate() }
        let loading = Task { await handle.activate() }
        for _ in 0..<200 where control.count == 0 { try await Task.sleep(for: .milliseconds(2)) }
        handle.beginUninstall()
        let uninstalling = Task { await handle.prepareForUninstall() }
        control.release()
        await loading.value
        let result = await uninstalling.value
        XCTAssertEqual(result.outcome, .succeeded)
        XCTAssertEqual(control.count, 1)
        XCTAssertEqual(handle.state, .off)
    }

    func testConcurrentHostReloadsShareHandlesAndLoading() async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Fixtures.writeBundle(Fixtures.manifest(), name: "Fixture", into: directory)
        let control = ModuleLoadControl()
        defer { control.release() }
        let host = ModuleHost(modulesDirectory: directory, settings: SettingsStore(defaults: Fixtures.defaults()),
                              permissions: FakePermissions(), privileged: nil, loader: { _ in control.load() })
        let tasks = (0..<12).map { _ in Task { await host.reload() } }
        for _ in 0..<200 where control.count == 0 { try await Task.sleep(for: .milliseconds(2)) }
        let first = try XCTUnwrap(host.handles.first)
        control.release()
        for task in tasks { await task.value }
        XCTAssertEqual(control.count, 1)
        XCTAssertTrue(host.handles.first === first)
        host.handles.forEach { $0.deactivate() }
        host.scheduler.stopAll()
    }
}
