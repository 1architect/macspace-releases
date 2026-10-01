import XCTest
import MacSpaceSdk
@testable import MacSpaceApp

final class ScannerTests: XCTestCase {
    func testFindsBundlesSortsThemAndReportsProblems() throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Fixtures.writeBundle(Fixtures.manifest(id: "com.test.b", order: 20), name: "B", into: directory)
        try Fixtures.writeBundle(Fixtures.manifest(id: "com.test.a", order: 10), name: "A", into: directory)
        try Fixtures.writeBundle(Fixtures.manifest(id: "com.test.a", order: 30), name: "Duplicate", into: directory)
        try Fixtures.writeBundle(Fixtures.manifest(), name: "Broken", into: directory, raw: Data("{".utf8))
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("NoManifest.macspacemodule"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("NotAModule"), withIntermediateDirectories: true)

        let found = ModuleScanner.scan(directory: directory)
        XCTAssertEqual(found.modules.map(\.id), ["com.test.a", "com.test.b"])
        XCTAssertEqual(Set(found.problems.map(\.bundleName)), ["Duplicate.macspacemodule", "Broken.macspacemodule", "NoManifest.macspacemodule"])
    }

    func testCompatibility() {
        let sonoma = OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)
        XCTAssertEqual(ModuleScanner.compatibility(of: Fixtures.manifest(minimumMacOS: "27.0"), systemVersion: sonoma),
                       .incompatible(reason: "Needs macOS 27.0 or later."))
        XCTAssertEqual(ModuleScanner.compatibility(of: Fixtures.manifest(minimumMacOS: "14.0"), systemVersion: sonoma), .compatible)
        XCTAssertEqual(ModuleScanner.compatibility(of: Fixtures.manifest(minimumMacOS: "27"), systemVersion: OperatingSystemVersion(majorVersion: 27, minorVersion: 2, patchVersion: 0)), .compatible)
        guard case .incompatible = ModuleScanner.compatibility(of: Fixtures.manifest(sdkVersion: 99), systemVersion: sonoma) else { return XCTFail() }
    }
}

@MainActor
final class HostTests: XCTestCase {
    private func makeHost(modules: [(ModuleManifest, String)], calls: Calls = Calls(), permissions: FakePermissions = FakePermissions(),
                          directory: URL) throws -> ModuleHost {
        for (manifest, name) in modules { try Fixtures.writeBundle(manifest, name: name, into: directory) }
        return ModuleHost(modulesDirectory: directory, settings: SettingsStore(defaults: Fixtures.defaults()), permissions: permissions,
                          loader: { _ in FakeModule(calls: calls) })
    }

    func testReloadActivatesEnabledModulesAndTogglingStopsThem() async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = try makeHost(modules: [(Fixtures.manifest(id: "com.test.a"), "A")], directory: directory)
        await host.reload()
        let handle = try XCTUnwrap(host.handles.first)
        XCTAssertEqual(handle.state, .ready)
        XCTAssertEqual(handle.screen?.title, "Fake")
        XCTAssertEqual(host.activeHandles.count, 1)

        await host.setEnabled(false, module: "com.test.a")
        XCTAssertEqual(handle.state, .off)
        XCTAssertNil(handle.screen)
        XCTAssertTrue(host.activeHandles.isEmpty)
        await host.setEnabled(true, module: "com.test.a")
        XCTAssertEqual(handle.state, .ready)
    }

    func testIncompatibleModulesAreNeverLoaded() async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let loaded = Calls()
        try Fixtures.writeBundle(Fixtures.manifest(id: "com.test.old", minimumMacOS: "99.0"), name: "Old", into: directory)
        let host = ModuleHost(modulesDirectory: directory, settings: SettingsStore(defaults: Fixtures.defaults()), permissions: FakePermissions(),
                              loader: { _ in loaded.add("loaded"); return FakeModule() })
        await host.reload()
        XCTAssertEqual(host.handles.first?.state, .incompatible("Needs macOS 99.0 or later."))
        XCTAssertTrue(loaded.all.isEmpty)
        await host.setEnabled(true, module: "com.test.old")
        XCTAssertTrue(loaded.all.isEmpty)
    }

    func testALoadFailureIsShownNotThrown() async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Fixtures.writeBundle(Fixtures.manifest(), name: "A", into: directory)
        let host = ModuleHost(modulesDirectory: directory, settings: SettingsStore(defaults: Fixtures.defaults()), permissions: FakePermissions(),
                              loader: { _ in throw ModuleLoader.LoadError.noPrincipalClass })
        await host.reload()
        guard case let .failed(reason)? = host.handles.first?.state else { return XCTFail("expected a failure") }
        XCTAssertTrue(reason.contains("principal class"))
    }

    func testActionsRunWithParametersProgressAndRefresh() async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let calls = Calls()
        let host = try makeHost(modules: [(Fixtures.manifest(), "A")], calls: calls, directory: directory)
        await host.reload()
        let handle = try XCTUnwrap(host.handles.first)
        await handle.perform(Action(id: "toggle", title: "T", parameters: ["id": "x"]), extraParameters: ["value": "true"])
        XCTAssertEqual(calls.all, ["perform:toggle:true"])
        XCTAssertEqual(handle.lastResult?.outcome, .succeeded)
        XCTAssertNil(handle.progress, "progress clears when the action ends")
        await handle.perform(Action(id: "fail", title: "F"))
        XCTAssertEqual(handle.lastResult?.outcome, .failed)
    }

    func testMissingPermissionsStopAnActionBeforeTheModuleIsCalled() async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let calls = Calls()
        let host = try makeHost(modules: [(Fixtures.manifest(), "A")], calls: calls,
                                permissions: FakePermissions(states: [.fullDiskAccess: .missing]), directory: directory)
        await host.reload()
        let handle = try XCTUnwrap(host.handles.first)
        XCTAssertEqual(handle.missingPermissions(), [.fullDiskAccess])
        await handle.perform(Action(id: "clean", title: "Clean", requires: [.fullDiskAccess]))
        XCTAssertTrue(calls.all.isEmpty)
        XCTAssertEqual(handle.lastResult?.outcome, .needsAttention)
        await handle.perform(Action(id: "other", title: "Other"))
        XCTAssertEqual(calls.all, ["perform:other:-"], "actions that need nothing still run")
    }

    func testBackgroundTasksRunOnlyWhenEnabledAndStopWhenTurnedOff() async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let calls = Calls()
        let task = BackgroundTaskDefinition(id: "watch", title: "Watch", intervalSeconds: 3600)
        let host = try makeHost(modules: [(Fixtures.manifest(tasks: [task]), "A")], calls: calls, directory: directory)
        await host.reload()
        XCTAssertTrue(host.scheduler.runningTaskKeys.isEmpty, "off by default")

        host.setBackgroundTask(true, "watch", module: "com.test.fake")
        XCTAssertEqual(host.scheduler.runningTaskKeys, ["com.test.fake/watch"])
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(calls.all, ["task:watch"])

        await host.setEnabled(false, module: "com.test.fake")
        XCTAssertTrue(host.scheduler.runningTaskKeys.isEmpty, "turning the module off stops its tasks")
        host.setBackgroundTask(false, "watch", module: "com.test.fake")
        host.scheduler.stopAll()
    }
}

final class SettingsTests: XCTestCase {
    func testDefaultsComeFromTheManifestAndUserChoicesWin() {
        let store = SettingsStore(defaults: Fixtures.defaults())
        let manifest = Fixtures.manifest(tasks: [BackgroundTaskDefinition(id: "watch", title: "W", defaultEnabled: true, intervalSeconds: 60)])
        XCTAssertTrue(store.isEnabled(module: manifest.id))
        let options = store.optionStore(for: manifest)
        XCTAssertTrue(options.bool("flag"))
        XCTAssertTrue(options.isBackgroundTaskEnabled("watch"))

        store.setEnabled(false, module: manifest.id)
        store.setOption(.bool(false), "flag", module: manifest.id)
        store.setBackgroundTask(false, "watch", module: manifest.id)
        XCTAssertFalse(store.isEnabled(module: manifest.id))
        XCTAssertFalse(store.optionStore(for: manifest).bool("flag"))
        XCTAssertFalse(store.optionStore(for: manifest).isBackgroundTaskEnabled("watch"))
        XCTAssertFalse(options.bool("unknown"))
    }
}
