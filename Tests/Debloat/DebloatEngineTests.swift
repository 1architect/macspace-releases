import XCTest
import MacSpacePlatform
@testable import MacSpaceDebloatPrivileged
import MacSpacePlatform

final class DebloatEngineTests: XCTestCase {
    private let userPref = ControlSetting.preference(.user, "com.example.test", "Enabled", desired: .bool(false), fallback: .absent)
    private let systemPref = ControlSetting.preference(.systemFile, "/Library/Example/History", "AutoSubmit", desired: .bool(false), fallback: nil)
    private let agent = ControlSetting.service(.gui, "com.example.agent")
    private let daemon = ControlSetting.service(.system, "com.example.daemon")

    private var controls: [DebloatControl] {
        [
            DebloatControl(id: "test.pref", title: "Pref", summary: "", category: .telemetry, mechanism: .userPreference,
                           risk: .low, restart: .none, settings: [userPref], validatedBuilds: ["26B5091g"]),
            DebloatControl(id: "test.mixed", title: "Mixed", summary: "", category: .telemetry, mechanism: .launchdOverride,
                           risk: .high, restart: .reboot, settings: [agent, daemon],
                           effect: .processesAbsent(["/usr/libexec/exampleagent"]), breaks: ["Example feature"]),
            DebloatControl(id: "test.system", title: "System", summary: "", category: .telemetry, mechanism: .systemPreference,
                           risk: .low, restart: .none, settings: [systemPref], effect: .diagnosticSubmission, validatedBuilds: ["26B5091g"]),
        ]
    }

    private func makeEngine() -> (DebloatEngine, FakeDebloatSystem, MemoryJournalStore) {
        let system = FakeDebloatSystem(controls: controls)
        let journal = MemoryJournalStore()
        return (DebloatEngine(controls: controls, system: system, journal: journal), system, journal)
    }

    private func state(_ engine: DebloatEngine, _ id: String) throws -> ControlState {
        engine.status(of: try engine.control(id)).state
    }

    // MARK: Status

    func testStatusStates() throws {
        let (engine, system, _) = makeEngine()
        XCTAssertEqual(try state(engine, "test.pref"), .stock)
        system.preferences[userPref.id] = .bool(false)
        XCTAssertEqual(try state(engine, "test.pref"), .debloated)
        system.preferences[userPref.id] = .int(0)
        XCTAssertEqual(try state(engine, "test.pref"), .debloated, "0 and false are the same preference value")

        system.overrides[agent.id] = true
        XCTAssertEqual(try state(engine, "test.mixed"), .partial)
        system.overrides[daemon.id] = true
        XCTAssertEqual(try state(engine, "test.mixed"), .debloated)

        system.jobs.removeAll()
        XCTAssertEqual(try state(engine, "test.mixed"), .unavailable)

        system.unreadable.insert(userPref.id)
        XCTAssertEqual(try state(engine, "test.pref"), .unknown)
    }

    // MARK: Plans

    func testUntestedControlsApplyWithANoteToCheckThem() throws {
        let (engine, _, _) = makeEngine()
        let allowed = try engine.plan(.apply, controlIDs: ["test.mixed"])[0]
        XCTAssertTrue(allowed.runnable, "no control is gated by macOS build or by being untested")
        XCTAssertTrue(allowed.warnings.contains { $0.contains("Not tested yet") })
        XCTAssertTrue(allowed.warnings.contains { $0.contains("Example feature") })
        XCTAssertTrue(allowed.warnings.contains { $0.contains("need root") })
        XCTAssertEqual(allowed.steps.map(\.privilege), [.user, .root])
    }

    func testUnknownControlThrows() {
        let (engine, _, _) = makeEngine()
        XCTAssertThrowsError(try engine.plan(.apply, controlIDs: ["nope"])) { error in
            XCTAssertEqual(error as? DebloatEngineError, .unknownControl("nope"))
        }
    }

    // MARK: Execution

    func testApplyJournalsBeforeValueAndReadsBack() throws {
        let (engine, system, journal) = makeEngine()
        system.preferences[userPref.id] = .bool(true)
        let result = engine.execute(try engine.plan(.apply, controlIDs: ["test.pref"]))[0]
        XCTAssertTrue(result.executed)
        XCTAssertEqual(result.steps.map(\.outcome), [.changed])
        XCTAssertEqual(result.statusAfter?.state, .debloated)
        XCTAssertEqual(result.statusAfter?.appliedAt, system.clock)
        let entry = try XCTUnwrap(journal.load(.user).entries.first)
        XCTAssertEqual(entry.before, .value(.bool(true)))
        XCTAssertEqual(entry.after, .value(.bool(false)))
        XCTAssertEqual(entry.build, "26B5091g")
    }

    func testStepsForAnotherPrivilegeAreSkipped() throws {
        let (engine, system, journal) = makeEngine()
        let plans = try engine.plan(.apply, controlIDs: ["test.mixed"], options: DebloatPlanOptions())
        let result = engine.execute(plans)[0]
        XCTAssertEqual(result.steps.map(\.outcome), [.changed, .skipped])
        XCTAssertEqual(result.statusAfter?.state, .partial)
        XCTAssertEqual(system.overrides[agent.id], true)
        XCTAssertNil(system.overrides[daemon.id])
        XCTAssertEqual(journal.load(.user).entries.count, 1)
        XCTAssertTrue(journal.load(.root).entries.isEmpty)

        system.env.runningAsRoot = true
        let rootResult = engine.execute(try engine.plan(.apply, controlIDs: ["test.mixed"], options: DebloatPlanOptions()))[0]
        XCTAssertEqual(rootResult.steps.map(\.outcome), [.alreadySatisfied, .changed])
        XCTAssertEqual(journal.load(.root).entries.count, 1)
        XCTAssertEqual(rootResult.statusAfter?.state, .debloated)
    }

    func testRevertRestoresTheOriginalValueEvenAfterReapplying() throws {
        let (engine, system, journal) = makeEngine()
        system.preferences[userPref.id] = .bool(true)
        _ = engine.execute(try engine.plan(.apply, controlIDs: ["test.pref"]))
        system.clock += 60
        system.preferences[userPref.id] = .bool(true) // e.g. an OS update resets it
        XCTAssertEqual(try state(engine, "test.pref"), .drifted)
        _ = engine.execute(try engine.plan(.apply, controlIDs: ["test.pref"]))
        XCTAssertEqual(journal.load(.user).outstanding.count, 2)

        system.clock += 60
        let result = engine.execute(try engine.plan(.revert, controlIDs: ["test.pref"]))[0]
        XCTAssertEqual(result.steps.map(\.outcome), [.changed])
        XCTAssertEqual(system.preferences[userPref.id], .bool(true))
        XCTAssertTrue(journal.load(.user).outstanding.isEmpty)
        XCTAssertEqual(journal.load(.user).entries.last?.action, .revert)
        XCTAssertNil(result.statusAfter?.appliedAt)
    }

    func testRevertToAbsentDeletesThePreference() throws {
        let (engine, system, _) = makeEngine()
        _ = engine.execute(try engine.plan(.apply, controlIDs: ["test.pref"]))
        XCTAssertEqual(system.preferences[userPref.id], .bool(false))
        _ = engine.execute(try engine.plan(.revert, controlIDs: ["test.pref"]))
        XCTAssertNil(system.preferences[userPref.id])
        XCTAssertEqual(system.writes.last?.1, .absent)
    }

    func testRevertAfterLaunchdClearedTheOverrideWritesNothing() throws {
        let (engine, system, journal) = makeEngine()
        system.env.sip = .disabled
        _ = engine.execute(try engine.plan(.apply, controlIDs: ["test.mixed"], options: DebloatPlanOptions()))
        system.overrides[agent.id] = nil // cleared by launchd at login
        let writes = system.writes.count
        let result = engine.execute(try engine.plan(.revert, controlIDs: ["test.mixed"]))[0]
        XCTAssertEqual(result.steps.first?.outcome, .alreadySatisfied)
        XCTAssertEqual(system.writes.count, writes, "no explicit enable is written")
        XCTAssertTrue(journal.load(.user).outstanding.isEmpty, "the journal entry is closed")
    }

    func testRevertAlsoUndoesSettingsTheControlNoLongerContains() throws {
        let (engine, system, journal) = makeEngine()
        let removed = ControlSetting.service(.gui, "com.example.removed")
        system.jobs.append(LaunchdJob(label: "com.example.removed", domain: .gui, program: nil, plistPath: "/System/Library/LaunchAgents/x.plist",
                                      disabledByDefault: nil, conditionallyDisabled: false))
        system.overrides[removed.id] = true
        var log = journal.load(.user)
        log.entries.append(JournalEntry(at: system.clock - 60, controlID: "test.pref", setting: removed, action: .apply,
                                        before: .absent, after: .launchdOverride(disabled: true), build: "26B5091g"))
        try journal.save(log, .user)

        let plan = try engine.plan(.revert, controlIDs: ["test.pref"])[0]
        XCTAssertEqual(plan.steps.map(\.setting.id), [userPref.id, removed.id])
        _ = engine.execute([plan])
        XCTAssertEqual(system.overrides[removed.id], false, "explicit enable, the closest launchd state to 'no override'")
        XCTAssertTrue(journal.load(.user).outstanding.isEmpty)
    }

    func testRevertLeavesSettingsMACSPACENeverChanged() throws {
        let (engine, system, _) = makeEngine()
        system.overrides[agent.id] = true // the user's own choice
        let plan = try engine.plan(.revert, controlIDs: ["test.mixed"])[0]
        XCTAssertTrue(plan.steps.allSatisfy(\.alreadySatisfied))
        _ = engine.execute([plan])
        XCTAssertTrue(system.writes.isEmpty)
        XCTAssertEqual(system.overrides[agent.id], true)
    }

    func testRestoreDefaultsUsesFallbacksAndExplainsLaunchdLimits() throws {
        let (engine, system, _) = makeEngine()
        system.overrides[agent.id] = true
        system.preferences[systemPref.id] = .bool(false)
        let options = DebloatPlanOptions(restoreFallbacks: true)
        let mixed = try engine.plan(.revert, controlIDs: ["test.mixed"], options: options)[0]
        XCTAssertEqual(mixed.steps[0].to, .launchdOverride(disabled: false))
        XCTAssertTrue(mixed.steps[0].warning?.contains("explicit enable") ?? false)

        let systemPlan = try engine.plan(.revert, controlIDs: ["test.system"], options: options)[0]
        XCTAssertTrue(systemPlan.steps[0].blocker?.contains("original value is unknown") ?? false)
    }

    func testFailedWriteRemovesTheJournalEntry() throws {
        let (engine, system, journal) = makeEngine()
        system.failingWrites.insert(userPref.id)
        let result = engine.execute(try engine.plan(.apply, controlIDs: ["test.pref"]))[0]
        XCTAssertEqual(result.steps.map(\.outcome), [.failed])
        XCTAssertFalse(result.executed)
        XCTAssertTrue(journal.load(.user).entries.isEmpty)
    }

    func testJournalFailurePreventsTheChange() throws {
        let (engine, system, journal) = makeEngine()
        journal.failSaves = true
        let result = engine.execute(try engine.plan(.apply, controlIDs: ["test.pref"]))[0]
        XCTAssertEqual(result.steps.map(\.outcome), [.failed])
        XCTAssertTrue(system.writes.isEmpty)
    }

    func testWriteThatDoesNotStickIsReportedButStaysJournaled() throws {
        let (engine, system, journal) = makeEngine()
        system.ignoredWrites.insert(userPref.id)
        let result = engine.execute(try engine.plan(.apply, controlIDs: ["test.pref"]))[0]
        XCTAssertEqual(result.steps.map(\.outcome), [.failed])
        XCTAssertTrue(result.steps[0].detail?.contains("does not read back") ?? false)
        XCTAssertEqual(journal.load(.user).entries.count, 1)
    }

    func testUnreadableSettingBlocksTheStep() throws {
        let (engine, system, _) = makeEngine()
        system.unreadable.insert(userPref.id)
        let result = engine.execute(try engine.plan(.apply, controlIDs: ["test.pref"]))[0]
        XCTAssertEqual(result.steps.map(\.outcome), [.blocked])
        XCTAssertTrue(system.writes.isEmpty)
    }

    // MARK: Effects

    func testProcessEffectIsPendingUntilRestartThenIneffectiveIfRelaunched() throws {
        let (engine, system, _) = makeEngine()
        system.env.runningAsRoot = false
        system.overrides[daemon.id] = true
        system.runningProcesses = [process("/usr/libexec/exampleagent", elapsed: 3600)]
        _ = engine.execute(try engine.plan(.apply, controlIDs: ["test.mixed"], options: DebloatPlanOptions()))
        XCTAssertEqual(engine.status(of: try engine.control("test.mixed")).effect?.state, .pending)

        system.clock += 600
        system.runningProcesses = [process("/usr/libexec/exampleagent", elapsed: 10)]
        let relaunched = engine.status(of: try engine.control("test.mixed")).effect
        XCTAssertEqual(relaunched?.state, .ineffective)

        system.runningProcesses = []
        XCTAssertEqual(engine.status(of: try engine.control("test.mixed")).effect?.state, .effective)
    }

    func testKeepAliveRelaunchInTheSameSessionIsPendingNotIneffective() throws {
        // Observed for com.apple.campo on 26B5091g: after `launchctl disable`, KeepAlive relaunched the process
        // within seconds because the job stays loaded until the domain is rebuilt.
        let (engine, system, _) = makeEngine()
        system.env.bootedAt = system.clock - 86_400
        system.overrides[daemon.id] = true
        _ = engine.execute(try engine.plan(.apply, controlIDs: ["test.mixed"], options: DebloatPlanOptions()))
        system.clock += 60
        system.runningProcesses = [process("/usr/libexec/exampleagent", elapsed: 5)]
        let pending = engine.status(of: try engine.control("test.mixed")).effect
        XCTAssertEqual(pending?.state, .pending)
        XCTAssertTrue(pending?.detail.contains("immediately") ?? false)

        system.env.bootedAt = system.clock // rebooted after the change, and the process is back
        XCTAssertEqual(engine.status(of: try engine.control("test.mixed")).effect?.state, .ineffective)
    }

    func testImmediateApplyStopsServicesAndRevertLoadsThem() throws {
        let (engine, system, _) = makeEngine()
        system.env.sip = .disabled // bootout of Apple agents worked with SIP disabled on 26B5091g
        system.runningProcesses = [process("/fake/com.example.agent")]
        let options = DebloatPlanOptions(immediate: true)
        let plan = try engine.plan(.apply, controlIDs: ["test.mixed"], options: options)[0]
        XCTAssertTrue(plan.immediate)
        XCTAssertTrue(plan.warnings.contains { $0.contains("bootout") })
        let applied = engine.execute([plan])[0]
        XCTAssertEqual(system.sessionCalls, ["stop com.example.agent"], "root step skipped, so only the user service is stopped")
        XCTAssertTrue(applied.steps[0].detail?.contains("stopped now") ?? false)
        XCTAssertEqual(system.runningProcesses, [])

        let reverted = engine.execute(try engine.plan(.revert, controlIDs: ["test.mixed"], options: options))[0]
        XCTAssertEqual(system.sessionCalls, ["stop com.example.agent", "start com.example.agent"])
        XCTAssertTrue(reverted.steps[0].detail?.contains("loaded now") ?? false)
    }

    func testImmediateStopsAnAlreadyDisabledServiceAndToleratesFailure() throws {
        let (engine, system, _) = makeEngine()
        system.overrides[agent.id] = true
        let options = DebloatPlanOptions(immediate: true)
        _ = engine.execute(try engine.plan(.apply, controlIDs: ["test.mixed"], options: options))
        XCTAssertEqual(system.sessionCalls, ["stop com.example.agent"])

        system.loadedServices = []
        let notLoaded = engine.execute(try engine.plan(.apply, controlIDs: ["test.mixed"], options: options))[0]
        XCTAssertEqual(notLoaded.steps[0].detail, "was not loaded")

        // Observed on 26B5091g with SIP enabled: bootout of Apple agents fails with launchctl error 150.
        system.failSessionCalls = true
        system.env.sip = .enabled
        system.overrides[agent.id] = nil
        let plan = try engine.plan(.apply, controlIDs: ["test.mixed"], options: options)[0]
        XCTAssertTrue(plan.warnings.contains { $0.contains("error 150") })
        let result = engine.execute([plan])[0]
        XCTAssertEqual(result.steps[0].outcome, .changed, "the override is set even if the service cannot be stopped now")
        XCTAssertTrue(result.steps[0].detail?.contains("System Integrity Protection blocks") ?? false)
    }

    func testDriftedControlEffectSaysUndone() throws {
        let (engine, system, _) = makeEngine()
        system.overrides[daemon.id] = true
        _ = engine.execute(try engine.plan(.apply, controlIDs: ["test.mixed"], options: DebloatPlanOptions()))
        system.overrides[agent.id] = nil // launchd cleared the override at boot
        system.runningProcesses = [process("/usr/libexec/exampleagent", elapsed: 5)]
        let status = engine.status(of: try engine.control("test.mixed"))
        XCTAssertEqual(status.state, .drifted)
        XCTAssertEqual(status.effect?.state, .notMeasured)
        XCTAssertEqual(status.effect?.detail, "Undone; running: exampleagent.")
    }

    func testControlMeasuredIneffectiveWithSIPIsBlockedAndNotControllable() throws {
        let control = DebloatControl(id: "test.cleared", title: "Cleared", summary: "", category: .siri, mechanism: .launchdOverride,
                                     risk: .medium, restart: .logout, settings: [agent], effect: .processesAbsent(["/usr/libexec/exampleagent"]),
                                     ineffectiveWithSIPBuilds: ["26B5091g"])
        let system = FakeDebloatSystem(controls: [control])
        let engine = DebloatEngine(controls: [control], system: system, journal: MemoryJournalStore())
        let options = DebloatPlanOptions()

        system.env.sip = .enabled
        let blocked = try engine.plan(.apply, controlIDs: ["test.cleared"], options: options)[0]
        XCTAssertTrue(blocked.blockers.contains { $0.contains("Measured to have no effect while SIP is enabled") && !$0.contains("26B") })
        XCTAssertEqual(engine.status(of: control).effect?.state, .notControllable)
        XCTAssertTrue(try engine.plan(.revert, controlIDs: ["test.cleared"])[0].runnable, "revert stays possible")

        system.env.build = "27A1"
        XCTAssertFalse(try engine.plan(.apply, controlIDs: ["test.cleared"], options: options)[0].runnable,
                       "a measurement on one build holds on every build")

        system.env.build = "26B5091g"
        system.env.sip = .disabled
        XCTAssertTrue(try engine.plan(.apply, controlIDs: ["test.cleared"], options: options)[0].runnable)
        XCTAssertNotEqual(engine.status(of: control).effect?.state, .notControllable)
    }

    func testLoggedOptInDecisionsSettleTheDiagnosticsEffect() throws {
        let (engine, system, _) = makeEngine()
        system.env.runningAsRoot = true
        system.env.isPrerelease = false
        system.preferences[systemPref.id] = .bool(true)
        system.history = DiagnosticSubmissionHistory(autoSubmit: false, thirdPartyDataSubmit: false, seedAutoSubmit: false,
                                                     lastFullSubmissionCalled: nil, lastFullSubmissionSuccess: system.clock - 100)
        _ = engine.execute(try engine.plan(.apply, controlIDs: ["test.system"]))
        system.decisions = [SubmissionDecision(at: system.clock - 50, optedIn: true)] // before the change: ignored
        XCTAssertEqual(engine.status(of: try engine.control("test.system")).effect?.state, .pending)

        system.decisions?.append(SubmissionDecision(at: system.clock + 60, optedIn: false))
        system.clock += 120
        let effective = engine.status(of: try engine.control("test.system")).effect
        XCTAssertEqual(effective?.state, .effective, "an OUT decision proves it without the 24 h window")
        XCTAssertTrue(effective?.detail.contains("optIn: OUT 1 time") ?? false)

        system.decisions?.append(SubmissionDecision(at: system.clock, optedIn: true))
        XCTAssertEqual(engine.status(of: try engine.control("test.system")).effect?.state, .ineffective)
    }

    /// The analytics policy read "Not working" with its profile approved: `log show --start` returned an IN decision from before
    /// the change, and an IN from before the user approved the profile counted although every later decision was OUT.
    func testTheLatestDecisionAfterTheChangeIsWhatCounts() throws {
        let (engine, system, _) = makeEngine()
        system.env.runningAsRoot = true
        system.env.isPrerelease = false
        system.preferences[systemPref.id] = .bool(true)
        _ = engine.execute(try engine.plan(.apply, controlIDs: ["test.system"]))
        system.history = DiagnosticSubmissionHistory(autoSubmit: false, thirdPartyDataSubmit: false, seedAutoSubmit: false,
                                                     lastFullSubmissionCalled: nil, lastFullSubmissionSuccess: system.clock + 4200)
        system.decisionsIgnoreStart = true
        system.decisions = [SubmissionDecision(at: system.clock - 600, optedIn: true),   // before the change
                            SubmissionDecision(at: system.clock + 60, optedIn: true),    // before the approval
                            SubmissionDecision(at: system.clock + 600, optedIn: false),
                            SubmissionDecision(at: system.clock + 4200, optedIn: false)]
        system.clock += 7200
        let effect = engine.status(of: try engine.control("test.system")).effect
        XCTAssertEqual(effect?.state, .effective)
        XCTAssertTrue(effect?.detail.contains("OUT 2 time(s) in a row") ?? false)
    }

    func testOptOutDecisionsOutrankTheSuccessTimestamp() throws {
        // Measured on 26B5091g: with the policy profile every run logged optIn: OUT, uploaded only a ~480-byte
        // check-in, and still advanced LastFullSubmissionSuccess.
        let (engine, system, _) = makeEngine()
        system.env.runningAsRoot = true
        system.env.isPrerelease = false
        system.preferences[systemPref.id] = .bool(true)
        _ = engine.execute(try engine.plan(.apply, controlIDs: ["test.system"]))
        system.clock += 3600
        system.history = DiagnosticSubmissionHistory(autoSubmit: false, thirdPartyDataSubmit: false, seedAutoSubmit: false,
                                                     lastFullSubmissionCalled: system.clock, lastFullSubmissionSuccess: system.clock)
        system.decisions = [SubmissionDecision(at: system.clock, optedIn: false)]
        XCTAssertEqual(engine.status(of: try engine.control("test.system")).effect?.state, .effective)
        system.decisions = []
        XCTAssertEqual(engine.status(of: try engine.control("test.system")).effect?.state, .ineffective, "without decisions the timestamp is all there is")
    }

    func testParsesSubmissionDecisionsFromNDJSON() {
        let text = """
        {"eventMessage":"Initiating submission for 'Primary' optIn: OUT","timestamp":"2026-09-28 11:21:06.081000-0300"}
        {"eventMessage":"Initiating submission for 'Primary' optIn: IN","timestamp":"2026-09-28 10:35:34.698000-0300"}
        {"eventMessage":"something else","timestamp":"2026-09-28 10:35:34.698000-0300"}
        {"count":33,"finished":1}
        """
        let decisions = SubmissionDecisionParser.parse(text)
        XCTAssertEqual(decisions.map(\.optedIn), [false, true])
        XCTAssertEqual(decisions[0].at, Date(timeIntervalSince1970: 1_790_605_266.081))
    }

    func testPartialControlsAreNotJudgedIneffective() throws {
        let (engine, system, _) = makeEngine()
        system.overrides[agent.id] = true // e.g. the user disabled one agent themselves
        system.runningProcesses = [process("/usr/libexec/exampleagent", elapsed: 10)]
        let status = engine.status(of: try engine.control("test.mixed"))
        XCTAssertEqual(status.state, .partial)
        XCTAssertEqual(status.effect?.state, .notMeasured)
        XCTAssertTrue(status.effect?.detail.hasPrefix("Partially applied") ?? false)
    }

    func testDiagnosticsEffect() throws {
        let (engine, system, _) = makeEngine()
        system.env.runningAsRoot = true
        system.preferences[systemPref.id] = .bool(true)
        system.history = DiagnosticSubmissionHistory(autoSubmit: true, thirdPartyDataSubmit: false, seedAutoSubmit: false,
                                                     lastFullSubmissionCalled: nil, lastFullSubmissionSuccess: system.clock - 100)
        system.env.isPrerelease = false
        _ = engine.execute(try engine.plan(.apply, controlIDs: ["test.system"]))
        XCTAssertEqual(engine.status(of: try engine.control("test.system")).effect?.state, .pending, "silence right after the change proves nothing")
        system.clock += DebloatEngine.submissionObservationWindow + 60
        XCTAssertEqual(engine.status(of: try engine.control("test.system")).effect?.state, .effective)

        system.history = DiagnosticSubmissionHistory(autoSubmit: false, thirdPartyDataSubmit: false, seedAutoSubmit: false,
                                                     lastFullSubmissionCalled: nil, lastFullSubmissionSuccess: system.clock + 100)
        XCTAssertEqual(engine.status(of: try engine.control("test.system")).effect?.state, .ineffective)

        system.env.isPrerelease = true
        system.history = DiagnosticSubmissionHistory(autoSubmit: false, thirdPartyDataSubmit: false, seedAutoSubmit: true,
                                                     lastFullSubmissionCalled: nil, lastFullSubmissionSuccess: system.clock + 100)
        XCTAssertEqual(engine.status(of: try engine.control("test.system")).effect?.state, .notControllable)
    }

    // MARK: Journal file store

    func testJournalFileStoreRoundTrips() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("macspace-journal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DebloatJournalStore(userURL: directory.appendingPathComponent("user/j.json"),
                                        systemURL: directory.appendingPathComponent("system/j.json"))
        XCTAssertTrue(store.load(.user).entries.isEmpty)
        let entry = JournalEntry(at: Date(timeIntervalSince1970: 1_800_000_000), controlID: "test.pref", setting: userPref,
                                 action: .apply, before: .absent, after: .value(.bool(false)), build: "26B5091g")
        try store.save(DebloatJournal(entries: [entry]), .user)
        XCTAssertEqual(store.load(.user).entries, [entry])
        XCTAssertTrue(store.load(.root).entries.isEmpty)
        XCTAssertEqual(store.allEntries, [entry])
    }
}
