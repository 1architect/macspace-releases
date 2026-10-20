import XCTest
import MacSpaceSdk
import MacSpacePlatform
@testable import MacSpaceDebloat
@testable import MacSpaceDebloatPrivileged

final class DebloatScreenBuilderTests: XCTestCase {
    private let helperControl = DebloatCatalog.control("diagnostics.tailspin")!
    private let profileControl = DebloatCatalog.control("apps.news-policy")!
    /// Tested and not a policy: what the page's main button switches.
    private let mainControl = DebloatCatalog.control("diagnostics.crash-reporter")!
    private let verifiedControl = DebloatCatalog.control("telemetry.diagnostics-policy")!

    private func status(_ id: String, _ state: ControlState, effect: EffectStatus? = nil) -> ControlStatus {
        ControlStatus(controlID: id, state: state, effect: effect, settings: [], tested: DebloatCatalog.control(id)?.tested ?? false, appliedAt: nil)
    }

    private let environment = DebloatEnvironment(build: "26B5091g", isPrerelease: true, sip: .enabled, userName: "u", uid: 501, runningAsRoot: false, fullDiskAccess: true)
    /// The controls a beta build is offered, as the live snapshot filters them on a Mac where no retired control is applied.
    private var offered: [DebloatControl] { DebloatCatalog.controls.filter { $0.isOffered(in: environment) && $0.retired == nil } }

    private func snapshot(_ statuses: [ControlStatus], blocked: Set<String> = []) -> DebloatSnapshot {
        DebloatSnapshot(controls: offered, statuses: Dictionary(uniqueKeysWithValues: statuses.map { ($0.controlID, $0) }),
                        environment: environment, cannotTakeEffect: blocked, takenAt: Date())
    }

    func testStoreSharesProgressWithPageJoiningTileAndKeepsCachedReadsQuiet() async throws {
        let fixture = snapshot([])
        let reads = SnapshotReads()
        let started = expectation(description: "scan started")
        let joined = expectation(description: "page joined current scan")
        let release = DispatchSemaphore(value: 0)
        let heard = LoadProgressRelay()
        let store = DebloatStore(builder: { progress in
            let read = reads.next()
            progress.report(0.25)
            if read == 1 {
                started.fulfill()
                reads.waitForRelease(release)
            }
            progress.report(0.75)
            return fixture
        })
        // The tile starts the scan without a sink. The page joins it later and must receive its current progress immediately.
        let tile = Task { await store.snapshot() }
        await fulfillment(of: [started], timeout: 2)
        let page = Task { await store.snapshot(progress: { value in
            heard.report(value)
            if value == 0.25 { joined.fulfill() }
        }) }
        await fulfillment(of: [joined], timeout: 2)
        release.signal()
        _ = await (tile.value, page.value)
        XCTAssertEqual(reads.total, 1)
        XCTAssertEqual(heard.fraction, 1)
        let cachedProgress = LoadProgressRelay()
        _ = await store.snapshot(progress: cachedProgress.report)
        XCTAssertNil(cachedProgress.fraction, "cached reads must not restore widget loading")
        XCTAssertEqual(reads.total, 1)
        await store.invalidate()
        let refreshed = LoadProgressRelay()
        _ = await store.snapshot(progress: refreshed.report)
        XCTAssertEqual(reads.total, 2)
        XCTAssertEqual(refreshed.fraction, 1)
    }

    /// A retired switch is listed only while it is applied, can then only be switched off, and is never counted, switched off by
    /// Disable all or re-applied; Enable all removes it.
    func testARetiredSwitchShowsOnlyWhereItIsAppliedAndOnlyToBeRemoved() throws {
        let retired = try XCTUnwrap(DebloatCatalog.control("ai.features-policy"))
        for state: ControlState in [.stock, .unavailable, .unknown] {
            XCTAssertFalse(DebloatStore.isShown(retired, in: environment, status: { self.status(retired.id, state) }), "\(state)")
        }
        for state: ControlState in [.debloated, .awaitingApproval, .partial, .drifted, .awaitingRemoval] {
            XCTAssertTrue(DebloatStore.isShown(retired, in: environment, status: { self.status(retired.id, state) }), "\(state)")
        }
        XCTAssertTrue(DebloatStore.isShown(mainControl, in: environment, status: { self.status(self.mainControl.id, .stock) }))

        func snap(_ state: ControlState) -> DebloatSnapshot {
            DebloatSnapshot(controls: offered + [retired], statuses: [retired.id: status(retired.id, state)], environment: environment,
                            cannotTakeEffect: [], takenAt: Date())
        }
        let applied = DebloatScreenBuilder.row(retired, snap(.debloated))
        XCTAssertTrue(applied.isOn && applied.isEnabled, "it can be switched off, which removes the policies")
        XCTAssertEqual(applied.badge?.text, "No longer works", "the pill says why it is still shown")
        XCTAssertTrue(applied.detail?.hasPrefix("Switch it off") == true)
        XCTAssertFalse(DebloatScreenBuilder.row(retired, snap(.partial)).isEnabled, "never switched on again")
        XCTAssertFalse(DebloatScreenBuilder.recommended(snap(.partial)).contains { $0.id == retired.id }, "not in Disable all")
        XCTAssertTrue(DebloatScreenBuilder.counts(snap(.drifted)).drifted.isEmpty, "not offered to disable again")
        XCTAssertEqual(DebloatScreenBuilder.counts(snap(.debloated)).total, offered.count, "not counted")
        XCTAssertTrue(DebloatScreenBuilder.switchedOff(snap(.debloated)).contains { $0.id == retired.id }, "Enable all removes it")
    }

    /// Generative search indexing stops Mail search, and the Apple Intelligence features policy makes macOS restrict Apple
    /// Intelligence, so where either is applied MacSpace switches it back on by itself.
    func testARetiredSwitchThatDoesHarmIsUndone() throws {
        let indexing = try XCTUnwrap(DebloatCatalog.control("ai.generative-indexing"))
        let features = try XCTUnwrap(DebloatCatalog.control("ai.features-policy"))
        func snap(_ states: [String: ControlState]) -> DebloatSnapshot {
            DebloatSnapshot(controls: offered + [indexing, features], statuses: Dictionary(uniqueKeysWithValues: states.map { ($0.key, status($0.key, $0.value)) }),
                            environment: environment, cannotTakeEffect: [], takenAt: Date())
        }
        XCTAssertEqual(DebloatScreenBuilder.retiredToUndo(snap([indexing.id: .debloated, features.id: .debloated])).map(\.id), [indexing.id, features.id])
        XCTAssertEqual(DebloatScreenBuilder.retiredToUndo(snap([features.id: .awaitingApproval])).map(\.id), [features.id], "a profile still waiting for approval too")
        XCTAssertEqual(DebloatScreenBuilder.retiredToUndo(snap([indexing.id: .partial])).map(\.id), [indexing.id], "part of it is enough")
        XCTAssertTrue(DebloatScreenBuilder.retiredToUndo(snap([indexing.id: .stock])).isEmpty)
    }

    /// A policy Screen Time or another profile sets is not offered: its row says who sets it, its switch cannot be flipped, and
    /// "Disable all" leaves it out.
    func testAPolicySetByAnotherProfileIsNotOffered() throws {
        let control = try XCTUnwrap(DebloatCatalog.control("suggestions.spotlight-internet-policy"))
        let elsewhere = ControlStatus(controlID: control.id, state: .stock, effect: nil, settings: [], tested: control.tested, appliedAt: nil,
                                      managedElsewhere: true)
        let snap = snapshot([elsewhere])
        let row = DebloatScreenBuilder.row(control, snap)
        XCTAssertFalse(row.isEnabled)
        XCTAssertEqual(row.badge?.text, "Set by another profile")
        XCTAssertFalse(row.detail?.contains("Screen Time") == true, "the pill says it; the (i) does not repeat it")
        XCTAssertFalse(DebloatScreenBuilder.recommended(snap).contains { $0.id == control.id })
    }

    func testEveryInfoTextIsStaticAndShortInEveryState() {
        let states: [(ControlState, EffectStatus?)] = [(.stock, nil), (.debloated, nil), (.drifted, nil), (.partial, nil), (.unavailable, nil),
                                                       (.debloated, EffectStatus(state: .ineffective, detail: "raw")),
                                                       (.debloated, EffectStatus(state: .pending, detail: "raw")),
                                                       (.debloated, EffectStatus(state: .notMeasured, detail: "raw"))]
        let baseline = InfoText.all(in: DebloatScreenBuilder.screen(snapshot([])))
        XCTAssertEqual(InfoText.violations(in: DebloatScreenBuilder.screen(snapshot([]))), [])
        for (state, effect) in states {
            let screen = DebloatScreenBuilder.screen(snapshot(offered.map { status($0.id, state, effect: effect) }))
            XCTAssertEqual(InfoText.violations(in: screen), [])
            XCTAssertEqual(Set(InfoText.all(in: screen)), Set(baseline), "the (i) does not change with the state: \(state)")
        }
    }

    func testEveryControlGetsOneToggleInItsCategory() {
        let screen = DebloatScreenBuilder.screen(snapshot([]))
        var ids: [String] = []
        for case let .toggles(list) in screen.widgets { ids += list.rows.map(\.id) }
        XCTAssertEqual(Set(ids), Set(offered.map(\.id)))
        XCTAssertEqual(ids.count, offered.count)
    }

    func testToggleStateAndBadgeFollowTheControlStateAndNoSwitchAsks() {
        let on = DebloatScreenBuilder.row(verifiedControl, snapshot([status(verifiedControl.id, .debloated,
                                                                            effect: EffectStatus(state: .effective, detail: "no submissions"))]))
        XCTAssertTrue(on.isOn, "Disable <feature> is on once MacSpace switched the feature off")
        XCTAssertNil(on.badge, "working as intended needs no badge")
        XCTAssertFalse(on.detail?.contains("no submissions") == true, "a measurement is shown only when something is wrong")
        XCTAssertNil(on.action.confirmation, "a switch never asks: it moves, then the change follows")

        let off = DebloatScreenBuilder.row(verifiedControl, snapshot([status(verifiedControl.id, .stock)]))
        XCTAssertFalse(off.isOn, "the feature still runs")
        XCTAssertNil(off.badge)
        XCTAssertNil(off.action.confirmation)

        let policy = DebloatScreenBuilder.row(profileControl, snapshot([status(profileControl.id, .stock)]))
        XCTAssertNil(policy.badge, "the policies were tested in the research (2026-09-29)")
        XCTAssertNil(policy.action.confirmation)

        let candidate = DebloatControl(id: "test.candidate", title: "Candidate", summary: "s", category: .telemetry, mechanism: .userPreference,
                                       risk: .low, restart: .none, settings: [.preference(.user, "com.example", "key", desired: .bool(false), fallback: nil)])
        let untested = DebloatScreenBuilder.row(candidate, snapshot([ControlStatus(controlID: candidate.id, state: .stock, effect: nil, settings: [],
                                                                                    tested: false, appliedAt: nil)]))
        XCTAssertNil(untested.badge, "an untested control carries no badge (removed 2026-10-07)")
        XCTAssertTrue(untested.isEnabled, "an untested control can be switched, to test it")
        XCTAssertEqual(untested.detail, "s", "what a switch does, behind its (i)")
    }

    func testStatesThatNeedAttentionAreVisible() {
        func badge(_ state: ControlState, effect: EffectStatus? = nil) -> String? {
            DebloatScreenBuilder.row(verifiedControl, snapshot([status(verifiedControl.id, state, effect: effect)])).badge?.text
        }
        XCTAssertEqual(badge(.drifted), "Undone by macOS")
        XCTAssertEqual(badge(.awaitingApproval), "Waiting for approval")
        XCTAssertEqual(badge(.debloated, effect: EffectStatus(state: .ineffective, detail: "")), "Not working")
        XCTAssertEqual(badge(.debloated, effect: EffectStatus(state: .pending, detail: "")), "Verifying")
        XCTAssertNil(badge(.debloated, effect: EffectStatus(state: .notMeasured, detail: "")), "no decision to read is not a failure")
        XCTAssertEqual(badge(.unavailable), "Not on this macOS")
        let waiting = DebloatScreenBuilder.row(verifiedControl, snapshot([status(verifiedControl.id, .awaitingApproval)]))
        XCTAssertTrue(waiting.isOn, "applied, waiting only for the user's approval")
    }

    func testEffectProblemsUseLocalizedInterfaceTextRatherThanRawHelperDiagnostics() {
        for effectState in [EffectState.ineffective, .notMeasured, .pending, .notControllable] {
            let status = status(verifiedControl.id, .debloated, effect: EffectStatus(state: effectState, detail: "RAW_HELPER_DIAGNOSTIC 2026-10-17T14:27:29Z"))
            let row = DebloatScreenBuilder.row(verifiedControl, snapshot([status]))
            XCTAssertEqual(row.detail, DebloatScreenBuilder.detail(verifiedControl), "the (i) is the same whatever the state")
            let help = row.badge?.help ?? ""
            XCTAssertFalse(help.contains("RAW_HELPER_DIAGNOSTIC"))
            XCTAssertFalse(help.contains("2026-10-17"))
        }
        let processControl = mainControl
        let pending = status(processControl.id, .debloated, effect: EffectStatus(state: .pending, detail: "until reboot"))
        XCTAssertEqual(DebloatScreenBuilder.badge(processControl, pending, cannotTakeEffect: false)?.text, processControl.restart == .reboot ? "Restart required" : "After restart")
        XCTAssertEqual(DebloatScreenBuilder.badge(processControl, pending, cannotTakeEffect: false)?.kind, .action)
    }

    func testSwitchingDisableOnAppliesTheProtection() {
        XCTAssertTrue(DebloatModule.appliesProtection(switchValue: "true"))
        XCTAssertFalse(DebloatModule.appliesProtection(switchValue: "false"))
        XCTAssertFalse(DebloatModule.appliesProtection(switchValue: nil))
    }

    func testControlsThatCannotWorkHereAreDisabled() {
        let row = DebloatScreenBuilder.row(helperControl, snapshot([status(helperControl.id, .stock)], blocked: [helperControl.id]))
        XCTAssertFalse(row.isEnabled)
        XCTAssertEqual(row.badge?.text, "Cannot take effect here")
    }

    func testOnlyRootControlsRequireTheHelper() {
        XCTAssertEqual(DebloatScreenBuilder.row(helperControl, snapshot([])).action.requires, [.privilegedHelper])
        XCTAssertTrue(DebloatScreenBuilder.row(profileControl, snapshot([])).action.requires.isEmpty, "a profile needs the user's approval, not root")
    }

    func testNoBannersTheMainButtonBecomesTheFix() throws {
        let screen = DebloatScreenBuilder.screen(snapshot([
            status(verifiedControl.id, .stock), status(helperControl.id, .stock),
            status(profileControl.id, .awaitingApproval), status("telemetry.on-device-speech-policy", .drifted),
        ]))
        XCTAssertFalse(screen.widgets.contains { if case .banner = $0 { return true } else { return false } }, "no banners")
        XCTAssertEqual(screen.widgets.last?.id, "policies", "the policies are listed apart, last")
        let reapply = try XCTUnwrap(screen.primary)
        XCTAssertEqual(reapply.id, "reapply", "what macOS enabled again comes first")
        XCTAssertEqual(reapply.parameters["ids"], "telemetry.on-device-speech-policy")
        XCTAssertNil(reapply.symbol, "words only")

        // The one profile changed: approving it is the fix, whether it switches policies off or back on.
        var approvingSnapshot = snapshot([status(verifiedControl.id, .stock), status(profileControl.id, .awaitingApproval)])
        approvingSnapshot.profileWork = .approve([profileControl.id])
        let approving = DebloatScreenBuilder.screen(approvingSnapshot)
        XCTAssertEqual(approving.primary?.id, "approvePending")
        XCTAssertEqual(approving.primary?.title, "Approve in System Settings")

        var removingSnapshot = snapshot([status(profileControl.id, .awaitingRemoval)])
        removingSnapshot.profileWork = .remove([ConfigurationProfileBuilder.profileIdentifier])
        let removing = DebloatScreenBuilder.screen(removingSnapshot)
        XCTAssertEqual(removing.primary?.id, "removePending")
        XCTAssertEqual(removing.primary?.requires, [.privilegedHelper], "removing a profile needs the helper, not approval")

        let running = DebloatScreenBuilder.screen(snapshot([status(verifiedControl.id, .stock), status(helperControl.id, .stock)]))
        XCTAssertEqual(Set(running.primary?.parameters["ids"]?.split(separator: ",").map(String.init) ?? []),
                       [verifiedControl.id, helperControl.id], "Disable all disables everything still enabled")
        XCTAssertNotNil(running.primary?.confirmation)
    }

    func testTheMainButtonSwitchesAllOffThenTurnsAllBackOn() throws {
        let running = DebloatScreenBuilder.screen(snapshot([status(mainControl.id, .stock), status(helperControl.id, .debloated)]))
        XCTAssertEqual(running.primary?.id, "applyRecommended", "a verified feature still runs")
        XCTAssertEqual(running.primary?.role, .prominent)

        let allOff = DebloatScreenBuilder.screen(snapshot([status(mainControl.id, .debloated), status(helperControl.id, .debloated),
                                                           status(profileControl.id, .debloated)]))
        let restore = try XCTUnwrap(allOff.primary)
        XCTAssertEqual(restore.id, "restoreAll")
        XCTAssertEqual(restore.role, .prominent)
        XCTAssertEqual(Set(restore.parameters["ids"]?.split(separator: ",").map(String.init) ?? []), [mainControl.id, helperControl.id, profileControl.id], "Turn all back on includes the policies")
        XCTAssertEqual(restore.requires, [.privilegedHelper], "a root control is among them")
        XCTAssertNotNil(restore.confirmation)

        XCTAssertNil(DebloatScreenBuilder.screen(snapshot([])).primary, "nothing verified to switch off and nothing to restore")
    }

    func testThePageOpensWithWhatNeedsTheUser() {
        let undone = DebloatScreenBuilder.screen(snapshot([status(verifiedControl.id, .drifted)]))
        XCTAssertEqual(undone.primary?.id, "reapply")
        XCTAssertEqual(undone.primary?.title, "Disable \(verifiedControl.title) again")
    }

    func testTile() {
        let none = DebloatScreenBuilder.tile(snapshot([]))
        XCTAssertEqual(none.status, "0/12 disabled")
        XCTAssertFalse(none.needsAttention)
        let drift = DebloatScreenBuilder.tile(snapshot([status(verifiedControl.id, .drifted)]))
        XCTAssertEqual(drift.status, "1 undone by macOS")
        XCTAssertTrue(drift.needsAttention)
        guard case let .dots(dots)? = drift.graphic else { return XCTFail() }
        XCTAssertEqual(dots.count, 12)
        XCTAssertEqual(dots.filter { $0 == .attention }.count, 1, "the undone control is the amber dot")
        XCTAssertEqual(DebloatScreenBuilder.tile(snapshot(offered.map { status($0.id, .debloated) })).status, "12/12 disabled")
    }

    func testSummarizingResultsMentionsApprovalRestartAndFailures() {
        func result(_ id: String, executed: Bool, outcome: StepOutcome, restart: RestartRequirement = .none) -> ControlChangeResult {
            let plan = ControlChangePlan(controlID: id, action: .apply, steps: [], blockers: [], warnings: [], restart: restart, immediate: false)
            return ControlChangeResult(plan: plan, executed: executed, steps: [StepResult(settingID: "s", outcome: outcome, detail: "detail")], statusAfter: nil)
        }
        let done = DebloatModule.summarize(.apply, [result("a", executed: true, outcome: .changed, restart: .reboot)])
        XCTAssertEqual(done.outcome, .succeeded)
        XCTAssertTrue(done.restartRequired)
        XCTAssertEqual(DebloatModule.summarize(.apply, [result("a", executed: true, outcome: .pendingApproval)]).outcome, .needsAttention)
        let failed = DebloatModule.summarize(.apply, [result("a", executed: false, outcome: .failed)])
        XCTAssertEqual(failed.outcome, .failed)
        XCTAssertFalse(failed.details.isEmpty)
    }
}

private final class SnapshotReads: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.withLock { count += 1; return count } }
    var total: Int { lock.withLock { count } }
    func waitForRelease(_ release: DispatchSemaphore) { _ = release.wait(timeout: .now() + 5) }
}

/// The watch's notification is the module's words; the app posts it (`ModuleServices.notify`).
final class DebloatWatchNoticeTests: XCTestCase {
    func testNoticeNamesWhatWasTurnedBackOn() {
        let one = DebloatWatchStore.notice(DebloatReapplied(at: Date(), titles: ["Siri"]))
        XCTAssertTrue(one.title.contains("Siri"))
        XCTAssertTrue(one.body.contains("Siri"))
        let two = DebloatWatchStore.notice(DebloatReapplied(at: Date(), titles: ["Siri", "Spotlight"]))
        XCTAssertTrue(two.title.contains("2"))
        XCTAssertNotEqual(one.body, two.body)
    }
}
