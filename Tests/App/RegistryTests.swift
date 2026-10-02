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

    func testHostAnnouncesWhenAModuleBecomesReadySoListsRedraw() async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = try makeHost(modules: [(Fixtures.manifest(), "A")], directory: directory)
        var changes = 0
        let watch = host.objectWillChange.sink { changes += 1 }
        await host.reload()
        let afterLoad = changes
        XCTAssertEqual(host.activeHandles.count, 1)
        await host.setEnabled(false, module: "com.test.fake")
        XCTAssertGreaterThan(changes, afterLoad, "switching a module off redraws the lists")
        XCTAssertGreaterThanOrEqual(afterLoad, 2, "the handles appearing and a handle turning ready are separate announcements")
        watch.cancel()
    }

    func testStartLoadsOnceNoMatterHowManyAsk() async throws {
        final class Count: @unchecked Sendable { var loads = 0; let lock = NSLock(); func bump() { lock.lock(); loads += 1; lock.unlock() } }
        let count = Count()
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Fixtures.writeBundle(Fixtures.manifest(), name: "A", into: directory)
        let host = ModuleHost(modulesDirectory: directory, settings: SettingsStore(defaults: Fixtures.defaults()), permissions: FakePermissions(),
                              loader: { _ in count.bump(); return SlowModule(delay: 0.2) })
        async let launch: Void = host.start()
        async let window: Void = host.start()
        _ = await (launch, window)
        XCTAssertEqual(count.loads, 1, "the app at launch and the window share one load")
        XCTAssertEqual(host.activeHandles.count, 1)
        await host.start()
        XCTAssertEqual(count.loads, 1)
    }

    func testModulesLoadSideBySide() async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for (id, name, order) in [("com.test.slow", "Slow", 1), ("com.test.fast", "Fast", 2)] {
            try Fixtures.writeBundle(Fixtures.manifest(id: id, order: order), name: name, into: directory)
        }
        let host = ModuleHost(modulesDirectory: directory, settings: SettingsStore(defaults: Fixtures.defaults()), permissions: FakePermissions(),
                              loader: { descriptor in SlowModule(delay: descriptor.id == "com.test.slow" ? 1.0 : 0) })
        let start = Date()
        let loading = Task { await host.reload() }
        try await Task.sleep(nanoseconds: 400_000_000)
        let fast = try XCTUnwrap(host.handles.first { $0.id == "com.test.fast" })
        XCTAssertNotNil(fast.screen, "the fast module is shown while the slow one is still scanning")
        await loading.value
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.8, "total time is the slowest module, not the sum")
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

    func testRefreshButtonMakesTheModuleForgetItsCache() async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let calls = Calls()
        let host = try makeHost(modules: [(Fixtures.manifest(), "A")], calls: calls, directory: directory)
        await host.reload()
        let handle = try XCTUnwrap(host.handles.first)
        XCTAssertFalse(calls.all.contains("invalidate"), "loading uses the cache")
        await handle.refresh(reload: true)
        XCTAssertEqual(calls.all.filter { $0 == "invalidate" }.count, 1)
        await handle.refresh()
        XCTAssertEqual(calls.all.filter { $0 == "invalidate" }.count, 1, "a plain refresh keeps the cache")
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

final class GeneralSettingsTests: XCTestCase {
    func testMenuBarIsOnByDefaultAndFollowsTheUsersChoice() {
        let defaults = Fixtures.defaults()
        XCTAssertTrue(GeneralSettings.showsInMenuBar(defaults))
        defaults.set(false, forKey: GeneralSettings.showInMenuBarKey)
        XCTAssertFalse(GeneralSettings.showsInMenuBar(defaults))
    }
}

@MainActor
final class UpdateControllerTests: XCTestCase {
    private func bundle(key: String?) throws -> Bundle {
        let directory = try Fixtures.temporaryDirectory().appendingPathComponent("T.bundle")
        let contents = directory.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var plist: [String: Any] = ["CFBundleIdentifier": "com.test.updates"]
        if let key { plist["SUPublicEDKey"] = key }
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        return try XCTUnwrap(Bundle(url: directory))
    }

    func testOnlyABuildWithARealKeyChecksForUpdates() throws {
        XCTAssertFalse(UpdateController.isConfigured(try bundle(key: nil)))
        XCTAssertFalse(UpdateController.isConfigured(try bundle(key: "")))
        XCTAssertFalse(UpdateController.isConfigured(try bundle(key: "__SPARKLE_PUBLIC_KEY__")), "an unfilled template is not a key")
        XCTAssertTrue(UpdateController.isConfigured(try bundle(key: "bRZJ3Zw4p8e8mxC+3xnP0aQe7oPD7rJ1Vz4nR0kQw1o=")))
        let controller = UpdateController(bundle: try bundle(key: nil))
        XCTAssertFalse(controller.isAvailable)
        XCTAssertFalse(controller.canCheck)
        controller.checkForUpdates() // must be a no-op, not a crash
    }
}
