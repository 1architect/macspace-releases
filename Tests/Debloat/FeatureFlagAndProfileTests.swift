import XCTest
import MacSpacePlatform
@testable import MacSpaceDebloatPrivileged
import MacSpacePlatform

final class FeatureFlagControlTests: XCTestCase {
    private let flag = ControlSetting.flag("IntelligenceFlow", "Campo")
    private var control: DebloatControl {
        DebloatControl(id: "test.flag", title: "Flag", summary: "", category: .siri, mechanism: .featureFlag, risk: .medium,
                       restart: .reboot, settings: [flag], effect: .processesAbsent(["/usr/libexec/flagged"]), validatedBuilds: ["26B5091g"])
    }

    func testFlagOverrideNeedsRootAndAppliesAfterReboot() throws {
        let system = FakeDebloatSystem(controls: [control])
        let journal = MemoryJournalStore()
        let engine = DebloatEngine(controls: [control], system: system, journal: journal)
        system.liveFlags["IntelligenceFlow/Campo"] = true
        system.env.bootedAt = system.clock - 3600
        system.runningProcesses = [process("/usr/libexec/flagged", elapsed: 3000)]

        XCTAssertEqual(flag.privilege, .root)
        XCTAssertEqual(engine.execute(try engine.plan(.apply, controlIDs: ["test.flag"]))[0].steps.map(\.outcome), [.skipped])

        system.env.runningAsRoot = true
        let result = engine.execute(try engine.plan(.apply, controlIDs: ["test.flag"]))[0]
        XCTAssertEqual(result.steps.map(\.outcome), [.changed])
        XCTAssertEqual(journal.load(.root).entries.first?.before, .absent)
        let status = engine.status(of: control)
        XCTAssertEqual(status.state, .debloated)
        XCTAssertEqual(status.settings[0].detail, "live: enabled; the override applies after a reboot")
        XCTAssertEqual(status.effect?.state, .pending)

        system.liveFlags["IntelligenceFlow/Campo"] = false // rebooted
        system.env.bootedAt = system.clock + 60
        system.runningProcesses = []
        XCTAssertEqual(engine.status(of: control).settings[0].detail, "live: disabled")
        XCTAssertEqual(engine.status(of: control).effect?.state, .effective)

        _ = engine.execute(try engine.plan(.revert, controlIDs: ["test.flag"]))
        XCTAssertNil(system.preferences[flag.id], "revert removes the override")
    }

    func testOverrideFileKeepsOtherEntriesAndIsRemovedWhenEmpty() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("macspace-ff-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("Domain/IntelligenceFlow.plist").path
        let campo = FeatureFlagSetting(domain: "IntelligenceFlow", feature: "Campo", enabled: false)
        let other = FeatureFlagSetting(domain: "IntelligenceFlow", feature: "Other", enabled: true)

        try LiveDebloatSystem.updateFeatureFlagOverride(other, enabled: true, path: path)
        try PropertyListSerialization.data(fromPropertyList: ["Other": ["Enabled": true], "Campo": ["DevelopmentPhase": "FeatureComplete"]],
                                           format: .xml, options: 0).write(to: URL(fileURLWithPath: path))
        try LiveDebloatSystem.updateFeatureFlagOverride(campo, enabled: false, path: path)
        var root = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: path)), options: [], format: nil) as? [String: [String: Any]])
        XCTAssertEqual(root["Campo"]?["Enabled"] as? Bool, false)
        XCTAssertNil(root["Campo"]?["DevelopmentPhase"], "libfeatureflags rejects Enabled together with DevelopmentPhase")
        XCTAssertEqual(root["Other"]?["Enabled"] as? Bool, true)
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o644)

        try LiveDebloatSystem.updateFeatureFlagOverride(campo, enabled: nil, path: path)
        root = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: path)), options: [], format: nil) as? [String: [String: Any]])
        XCTAssertNil(root["Campo"])
        try LiveDebloatSystem.updateFeatureFlagOverride(other, enabled: nil, path: path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "an empty override file is deleted")
    }

    func testLiveFeatureFlagProbe() {
        let system = LiveDebloatSystem(targetUser: nil)
        XCTAssertEqual(system.liveFeatureFlag(domain: "MacSpaceNonexistent", feature: "Nothing"), false)
        XCTAssertFalse(LiveDebloatSystem.systemFeatureExists(domain: "MacSpaceNonexistent", feature: "Nothing"))
    }

    func testCatalogFlagsExistOnMacOS27() throws {
        // The catalog's flags ship with macOS 27; older hosts (e.g. the macOS 15 CI runner) do not have them.
        try XCTSkipUnless(LiveDebloatSystem.systemFeatureExists(domain: "IntelligenceFlow", feature: "Campo"), "host predates macOS 27")
        for control in DebloatCatalog.controls {
            for flag in control.settings.compactMap(\.featureFlag) {
                XCTAssertTrue(LiveDebloatSystem.systemFeatureExists(domain: flag.domain, feature: flag.feature), "\(flag.domain)/\(flag.feature)")
            }
        }
    }
}

final class ConfigurationProfileTests: XCTestCase {
    private let diagnostics = [ControlSetting.managed("com.apple.SubmitDiagInfo", "AutoSubmit", desired: .bool(false)),
                               ControlSetting.managed("com.apple.applicationaccess", "allowDiagnosticSubmission", desired: .bool(false))]
    private let ads = [ControlSetting.managed("com.apple.applicationaccess", "allowApplePersonalizedAdvertising", desired: .bool(false))]

    private var controls: [DebloatControl] {
        [DebloatControl(id: "test.diag", title: "Diag", summary: "", category: .telemetry, mechanism: .configurationProfile,
                        risk: .low, restart: .none, settings: diagnostics, validatedBuilds: ["26B5091g"]),
         DebloatControl(id: "test.ads", title: "Ads", summary: "", category: .advertising, mechanism: .configurationProfile,
                        risk: .low, restart: .none, settings: ads, validatedBuilds: ["26B5091g"])]
    }

    func testBuilderGroupsPayloadsAndIsDeterministic() throws {
        let settings = (diagnostics + ads).map { $0.managed! }
        let data = try ConfigurationProfileBuilder.build(settings, controlID: "test.diag", title: "Diag")
        XCTAssertEqual(data, try ConfigurationProfileBuilder.build(settings, controlID: "test.diag", title: "Diag"))
        let root = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])
        XCTAssertEqual(root["PayloadIdentifier"] as? String, "com.macspace.policies.test.diag", "one profile per control")
        XCTAssertEqual(root["PayloadDisplayName"] as? String, "MacSpace: Diag")
        XCTAssertEqual(root["PayloadScope"] as? String, "System")
        let payloads = try XCTUnwrap(root["PayloadContent"] as? [[String: Any]])
        XCTAssertEqual(payloads.map { $0["PayloadType"] as? String }, ["com.apple.SubmitDiagInfo", "com.apple.applicationaccess"])
        XCTAssertEqual(payloads[1]["allowDiagnosticSubmission"] as? Bool, false)
        XCTAssertEqual(payloads[1]["allowApplePersonalizedAdvertising"] as? Bool, false)
        XCTAssertNotNil(UUID(uuidString: payloads[0]["PayloadUUID"] as! String))
        XCTAssertTrue(ConfigurationProfileBuilder.isMacSpaceProfile("com.macspace.policies"))
        XCTAssertTrue(ConfigurationProfileBuilder.isMacSpaceProfile("com.macspace.policies.test.diag"))
        XCTAssertFalse(ConfigurationProfileBuilder.isMacSpaceProfile("com.example.vpn"), "the helper removes MacSpace's profiles only")
        XCTAssertFalse(ConfigurationProfileBuilder.isMacSpaceProfile("com.macspace.policiesX"))
    }

    func testEachPolicyHasItsOwnProfileAndSwitchingBackOnNeedsNoApproval() throws {
        let system = FakeDebloatSystem(controls: controls)
        let engine = DebloatEngine(controls: controls, system: system, journal: MemoryJournalStore())

        let result = engine.execute(try engine.plan(.apply, controlIDs: ["test.diag", "test.ads"]))
        XCTAssertEqual(result.flatMap(\.steps).map(\.outcome), [.pendingApproval, .pendingApproval, .pendingApproval])
        XCTAssertEqual(system.stagedFileNames, ["MacSpace-test.diag.mobileconfig", "MacSpace-test.ads.mobileconfig"], "one profile per control")
        XCTAssertEqual(system.lastProfileValues, ["com.apple.applicationaccess:allowApplePersonalizedAdvertising": .bool(false)],
                       "a control's profile holds only its own policy")
        XCTAssertEqual(engine.status(of: controls[0]).state, .awaitingApproval)

        for setting in diagnostics + ads { system.forced[setting.id] = .bool(false) } // the user approved both
        XCTAssertEqual(engine.status(of: controls[0]).state, .debloated)

        // Switching one back on stages nothing for the user: its profile is removed, which the app asks the helper to do.
        let reverted = engine.execute(try engine.plan(.revert, controlIDs: ["test.ads"]))[0]
        XCTAssertEqual(system.stagedProfiles.count, 2, "the other policy's profile is not replaced, so nothing asks again")
        XCTAssertEqual(ConfigurationProfileBuilder.identifiers(inRemovalNeeded: reverted.steps[0].detail),
                       ["com.macspace.policies.test.ads", "com.macspace.policies"])
        XCTAssertEqual(engine.status(of: controls[1]).state, .awaitingRemoval, "until the profile is gone")
        XCTAssertEqual(engine.status(of: controls[0]).state, .debloated, "the other policy stays in force")

        // Where profiles can be removed (the helper), switching back on is done at once.
        system.removesProfiles = true
        let back = engine.execute(try engine.plan(.revert, controlIDs: ["test.diag"]))[0]
        XCTAssertEqual(back.steps.map(\.outcome), [.changed, .changed])
        XCTAssertEqual(system.removedProfiles, ["com.macspace.policies.test.diag", "com.macspace.policies"])
        for setting in diagnostics { system.forced[setting.id] = nil }
        XCTAssertEqual(engine.status(of: controls[0]).state, .stock)
    }

    func testAPolicyWithoutAJournalSwitchesBackOn() throws {
        // Applied by an earlier build: macOS enforces both controls, and the journal knows nothing.
        let system = FakeDebloatSystem(controls: controls)
        let engine = DebloatEngine(controls: controls, system: system, journal: MemoryJournalStore())
        for setting in diagnostics + ads { system.forced[setting.id] = .bool(false) }

        let reverted = engine.execute(try engine.plan(.revert, controlIDs: ["test.ads"], options: DebloatPlanOptions(restoreFallbacks: true)))[0]
        XCTAssertEqual(reverted.steps.map(\.outcome), [.pendingApproval], "switching it back on works without a saved value")
        XCTAssertNotNil(ConfigurationProfileBuilder.identifiers(inRemovalNeeded: reverted.steps[0].detail))
        XCTAssertTrue(system.stagedProfiles.isEmpty, "nothing for the user to approve")
        XCTAssertEqual(engine.status(of: controls[1]).state, .awaitingRemoval)
    }

    func testStagingFailureUndoesTheJournalEntries() throws {
        let system = FakeDebloatSystem(controls: controls)
        let journal = MemoryJournalStore()
        let engine = DebloatEngine(controls: controls, system: system, journal: journal)
        system.failStaging = true
        let result = engine.execute(try engine.plan(.apply, controlIDs: ["test.diag"]))[0]
        XCTAssertEqual(result.steps.map(\.outcome), [.failed, .failed])
        XCTAssertTrue(journal.load(.user).entries.isEmpty)
        XCTAssertEqual(engine.status(of: controls[0]).state, .stock)
    }

    func testAlreadyForcedValuesNeedNoProfile() throws {
        let system = FakeDebloatSystem(controls: controls)
        let engine = DebloatEngine(controls: controls, system: system, journal: MemoryJournalStore())
        for setting in diagnostics { system.forced[setting.id] = .bool(false) } // e.g. an MDM or another profile
        let result = engine.execute(try engine.plan(.apply, controlIDs: ["test.diag"]))[0]
        XCTAssertEqual(result.steps.map(\.outcome), [.alreadySatisfied, .alreadySatisfied])
        XCTAssertTrue(system.stagedProfiles.isEmpty)
    }
}
