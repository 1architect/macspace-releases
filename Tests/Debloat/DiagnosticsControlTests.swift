import XCTest
import MacSpacePlatform
@testable import MacSpaceDebloatPrivileged
import MacSpacePlatform

final class SIPRuleTests: XCTestCase {
    private let cleared = ControlSetting.service(.gui, "com.apple.sirittsd")
    private let removable = ControlSetting.service(.gui, "com.apple.ReportCrash")

    private func engine(_ settings: [ControlSetting]) -> (DebloatEngine, FakeDebloatSystem, DebloatControl) {
        let control = DebloatControl(id: "test.launchd", title: "L", summary: "", category: .diagnostics, mechanism: .launchdOverride,
                                     risk: .low, restart: .logout, settings: settings, effect: .processesAbsent(["/x"]))
        let system = FakeDebloatSystem(controls: [control])
        system.env.sip = .enabled
        system.removable = ["com.apple.ReportCrash", "com.apple.Siri.agent"]
        return (DebloatEngine(controls: [control], system: system, journal: MemoryJournalStore()), system, control)
    }

    func testControlWhoseServicesAreAllClearedIsBlocked() throws {
        let (engine, _, control) = engine([cleared])
        XCTAssertTrue(engine.cannotTakeEffect(control))
        let plan = try engine.plan(.apply, controlIDs: ["test.launchd"], options: DebloatPlanOptions(allowUnverified: true))[0]
        XCTAssertTrue(plan.blockers.contains { $0.contains("RemovableServices") })
        XCTAssertEqual(engine.status(of: control).effect?.state, .notControllable)
        XCTAssertTrue(engine.status(of: control).settings[0].detail?.contains("not in RemovableServices") ?? false)
    }

    func testRemovableServicesStayApplicable() throws {
        let (engine, _, control) = engine([removable])
        XCTAssertFalse(engine.cannotTakeEffect(control))
        let plan = try engine.plan(.apply, controlIDs: ["test.launchd"], options: DebloatPlanOptions(allowUnverified: true))[0]
        XCTAssertTrue(plan.runnable)
        XCTAssertFalse(plan.warnings.contains { $0.contains("will not honor") })
        XCTAssertNil(engine.status(of: control).settings[0].detail)
    }

    func testMixedControlWarnsAboutTheClearedServices() throws {
        let (engine, _, control) = engine([removable, cleared])
        XCTAssertFalse(engine.cannotTakeEffect(control))
        let plan = try engine.plan(.apply, controlIDs: ["test.launchd"], options: DebloatPlanOptions(allowUnverified: true))[0]
        XCTAssertTrue(plan.runnable)
        XCTAssertTrue(plan.warnings.contains { $0.contains("will not honor") && $0.hasSuffix(": com.apple.sirittsd.") })
    }

    func testRuleIsInactiveWithSIPDisabledOrUnreadablePolicy() {
        let (engine, system, control) = engine([cleared])
        system.env.sip = .disabled
        XCTAssertFalse(engine.cannotTakeEffect(control))
        system.env.sip = .enabled
        system.removable = nil
        XCTAssertFalse(engine.cannotTakeEffect(control))
    }

    func testForceEnabledServicesCannotTakeEffectEvenWhenRemovable() throws {
        let (engine, system, control) = engine([removable])
        system.forceEnabled = ["com.apple.ReportCrash"] // observed on 26B5091g
        XCTAssertTrue(engine.cannotTakeEffect(control))
        XCTAssertEqual(engine.status(of: control).effect?.state, .notControllable)
        XCTAssertTrue(engine.status(of: control).settings[0].detail?.contains("force-enables") ?? false)
        system.env.sip = .disabled
        XCTAssertTrue(engine.cannotTakeEffect(control), "force-enabled does not depend on SIP")
    }

    func testParsesForceEnabled() {
        XCTAssertTrue(LiveDebloatSystem.parseForceEnabled("\tstate = running\n\tproperties = force-enabled | supports transactions | system service\n"))
        XCTAssertFalse(LiveDebloatSystem.parseForceEnabled("\tproperties = supports transactions | system service\n"))
        XCTAssertFalse(LiveDebloatSystem.parseForceEnabled("Could not find service"))
    }

    func testParsesTheRootlessPolicy() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: [
            "RemovableServices": ["com.apple.ReportCrash": true, "com.apple.Off": false],
            "InstallerRemovableServices": ["com.apple.dz": true],
        ], format: .xml, options: 0)
        XCTAssertEqual(LiveDebloatSystem.parseRemovableServices(data), ["com.apple.ReportCrash"])
        XCTAssertNil(LiveDebloatSystem.parseRemovableServices(Data("x".utf8)))
    }

    func testLiveRootlessPolicyListsTheObservedSurvivors() throws {
        let live = try XCTUnwrap(LiveDebloatSystem(targetUser: nil).sipRemovableServices())
        for label in ["com.apple.Siri.agent", "com.apple.FolderActionsDispatcher", "com.apple.ReportCrash"] { XCTAssertTrue(live.contains(label), label) }
        for label in ["com.apple.campo", "com.apple.tipsd", "com.apple.sirittsd", "com.apple.analyticsd"] { XCTAssertFalse(live.contains(label), label) }
    }
}

final class SystemToolTests: XCTestCase {
    func testParsers() {
        XCTAssertEqual(LiveDebloatSystem.parseTailspinEnabled("\ntailspin has been enabled (default behavior)\n"), true)
        XCTAssertEqual(LiveDebloatSystem.parseTailspinEnabled("tailspin has been disabled\n"), false)
        XCTAssertNil(LiveDebloatSystem.parseTailspinEnabled("something else"))
        XCTAssertEqual(LiveDebloatSystem.parseMdutilIndexing("/:\n\tIndexing enabled. \n"), true)
        XCTAssertEqual(LiveDebloatSystem.parseMdutilIndexing("/:\n\tIndexing disabled.\n"), false)
        XCTAssertNil(LiveDebloatSystem.parseMdutilIndexing("/:\n\tError: unknown indexing state.\n"))
    }

    func testCommandsAndRevertFallback() {
        let system = LiveDebloatSystem(targetUser: nil)
        let tailspin = ControlSetting.tool(.tailspin)
        XCTAssertEqual(tailspin.privilege, .root)
        XCTAssertEqual(system.command(for: tailspin, value: .value(.bool(false))), ["/usr/bin/tailspin", "disable"])
        XCTAssertEqual(system.command(for: ControlSetting.tool(.spotlightIndexing), value: .value(.bool(true))), ["/usr/bin/mdutil", "-a", "-i", "on"])
        XCTAssertEqual(tailspin.fallbackValue, .value(.bool(true)), "tools ship enabled")
    }

    func testToolControlAppliesAsRootAndReverts() throws {
        let control = DebloatCatalog.control("diagnostics.tailspin")!
        let system = FakeDebloatSystem(controls: [control])
        let engine = DebloatEngine(controls: [control], system: system, journal: MemoryJournalStore())
        let setting = control.settings[0]
        system.preferences[setting.id] = .bool(true)
        system.env.runningAsRoot = true
        let options = DebloatPlanOptions(allowUnverified: true)
        XCTAssertEqual(engine.execute(try engine.plan(.apply, controlIDs: [control.id], options: options))[0].steps.map(\.outcome), [.changed])
        XCTAssertEqual(engine.status(of: control).state, .debloated)
        _ = engine.execute(try engine.plan(.revert, controlIDs: [control.id]))
        XCTAssertEqual(system.preferences[setting.id], .bool(true))
    }
}
