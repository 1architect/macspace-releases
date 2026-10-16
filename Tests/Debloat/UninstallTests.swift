import XCTest
import MacSpacePlatform
import MacSpaceSdk
@testable import MacSpaceDebloat
@testable import MacSpaceDebloatPrivileged

final class DebloatUninstallTests: XCTestCase {
    private func context(channel: (any PrivilegedChannel)? = nil) -> ModuleContext {
        ModuleContext(manifest: ModuleManifest(id: "test", name: "Test", summary: "", version: "1", symbol: ""),
                      options: EmptyOptions(), permissions: GrantedPermissions(), privileged: channel)
    }

    private struct EmptyOptions: OptionStore {
        func bool(_ id: String) -> Bool { false }
        func string(_ id: String) -> String { "" }
        func isBackgroundTaskEnabled(_ id: String) -> Bool { false }
    }

    private struct GrantedPermissions: PermissionChecker {
        func status(of permission: Permission) -> PermissionStatus { .granted }
    }

    func testRestoresOnlyJournaledPreferences() async throws {
        let setting = ControlSetting.preference(.user, "com.example", "Enabled", desired: .bool(false), fallback: .absent)
        let control = DebloatControl(id: "test", title: "Test", summary: "", category: .telemetry, mechanism: .userPreference,
                                     risk: .low, restart: .none, settings: [setting])
        let system = FakeDebloatSystem(controls: [control])
        let engine = DebloatEngine(controls: [control], system: system, journal: MemoryJournalStore())
        system.preferences[setting.id] = .bool(true)
        _ = engine.execute(try engine.plan(.apply, controlIDs: [control.id]))
        let result = await DebloatModule.prepareForUninstall(engine: engine, context: context())
        XCTAssertEqual(result.outcome, .succeeded)
        XCTAssertEqual(system.preferences[setting.id], .bool(true))
    }

    func testUnreadableRootSettingBlocksUninstall() async throws {
        let setting = ControlSetting.flag("Test", "Enabled")
        let control = DebloatControl(id: "test", title: "Test", summary: "", category: .telemetry, mechanism: .featureFlag,
                                     risk: .low, restart: .reboot, settings: [setting])
        let system = FakeDebloatSystem(controls: [control])
        system.env.runningAsRoot = true
        let engine = DebloatEngine(controls: [control], system: system, journal: MemoryJournalStore())
        _ = engine.execute(try engine.plan(.apply, controlIDs: [control.id]))
        system.env.runningAsRoot = false
        system.unreadable.insert(setting.id)
        let result = await DebloatModule.prepareForUninstall(engine: engine, context: context())
        XCTAssertEqual(result.outcome, .failed)
        XCTAssertFalse(result.details.isEmpty)
    }

    func testUnjournaledLegacyProfileNeedsRemovalBeforeUninstall() async {
        let system = FakeDebloatSystem(controls: [])
        system.installedValues[ConfigurationProfileBuilder.profileIdentifier] = [:]
        let engine = DebloatEngine(controls: [], system: system, journal: MemoryJournalStore())
        let result = await DebloatModule.prepareForUninstall(engine: engine, context: context())
        XCTAssertEqual(result.outcome, .failed, "cannot remove a profile without the helper")
        XCTAssertFalse(system.installedValues.isEmpty)
    }
}
