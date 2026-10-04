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

    private let environment = DebloatEnvironment(productVersion: "27.2", build: "26B5091g", isPrerelease: true, sip: .enabled, mdmEnrolled: false, depEnrolled: false, architecture: "arm64", userName: "u", uid: 501, runningAsRoot: false, fullDiskAccess: true)
    /// The controls a beta build is offered, as the live snapshot filters them.
    private var offered: [DebloatControl] { DebloatCatalog.controls.filter { $0.isOffered(in: environment) } }

    private func snapshot(_ statuses: [ControlStatus], blocked: Set<String> = []) -> DebloatSnapshot {
        DebloatSnapshot(controls: offered, statuses: Dictionary(uniqueKeysWithValues: statuses.map { ($0.controlID, $0) }),
                        environment: environment, cannotTakeEffect: blocked, takenAt: Date())
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
        XCTAssertFalse(on.isOn, "the switch shows the feature, which MacSpace switched off")
        XCTAssertNil(on.badge, "working as intended needs no badge")
        XCTAssertTrue(on.detail?.contains("Measured off") == true)
        XCTAssertNil(on.action.confirmation, "a switch never asks: it moves, then the change follows")

        let off = DebloatScreenBuilder.row(verifiedControl, snapshot([status(verifiedControl.id, .stock)]))
        XCTAssertTrue(off.isOn, "the feature still runs")
        XCTAssertNil(off.badge)
        XCTAssertNil(off.action.confirmation)

        let policy = DebloatScreenBuilder.row(profileControl, snapshot([status(profileControl.id, .stock)]))
        XCTAssertNil(policy.badge, "the policies were tested in the research (2026-09-29)")
        XCTAssertNil(policy.action.confirmation)

        let candidate = DebloatControl(id: "test.candidate", title: "Candidate", summary: "s", category: .telemetry, mechanism: .userPreference,
                                       risk: .low, restart: .none, settings: [.preference(.user, "com.example", "key", desired: .bool(false), fallback: nil)])
        let untested = DebloatScreenBuilder.row(candidate, snapshot([ControlStatus(controlID: candidate.id, state: .stock, effect: nil, settings: [],
                                                                                    tested: false, appliedAt: nil)]))
        XCTAssertEqual(untested.badge?.text, "Not tested")
        XCTAssertTrue(untested.isEnabled, "an untested control can be switched, to test it")
        XCTAssertTrue(untested.detail?.contains("Not tested yet") == true, "what a switch changes is in its tooltip")
    }

    func testStatesThatNeedAttentionAreVisible() {
        func badge(_ state: ControlState, effect: EffectStatus? = nil) -> String? {
            DebloatScreenBuilder.row(verifiedControl, snapshot([status(verifiedControl.id, state, effect: effect)])).badge?.text
        }
        XCTAssertEqual(badge(.drifted), "Undone by macOS")
        XCTAssertEqual(badge(.awaitingApproval), "Waiting for approval")
        XCTAssertEqual(badge(.debloated, effect: EffectStatus(state: .ineffective, detail: "")), "Not working")
        XCTAssertEqual(badge(.debloated, effect: EffectStatus(state: .pending, detail: "")), "After restart")
        XCTAssertEqual(badge(.unavailable), "Not on this macOS")
        let waiting = DebloatScreenBuilder.row(verifiedControl, snapshot([status(verifiedControl.id, .awaitingApproval)]))
        XCTAssertFalse(waiting.isOn, "applied, waiting only for the user's approval")
    }

    func testSwitchingTheFeatureOffAppliesTheProtection() {
        XCTAssertTrue(DebloatModule.appliesProtection(switchValue: "false"))
        XCTAssertFalse(DebloatModule.appliesProtection(switchValue: "true"))
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

    func testBannersAndTheRecommendedButton() {
        let screen = DebloatScreenBuilder.screen(snapshot([
            status(verifiedControl.id, .stock), status(helperControl.id, .stock),
            status(profileControl.id, .awaitingApproval), status("telemetry.on-device-speech-policy", .drifted),
        ]))
        XCTAssertEqual(screen.widgets.map(\.id).prefix(3), ["approval", "drifted", "cat:telemetry"])
        XCTAssertEqual(screen.widgets.last?.id, "policies", "the policies are listed apart, last")
        let primary = try? XCTUnwrap(screen.primary)
        XCTAssertEqual(Set(primary?.parameters["ids"]?.split(separator: ",").map(String.init) ?? []),
                       [verifiedControl.id, helperControl.id, "telemetry.on-device-speech-policy"],
                       "Switch all off switches off everything still on, what macOS switched back on included")
        XCTAssertNotNil(primary?.confirmation)

        let clean = DebloatScreenBuilder.screen(snapshot([]))
        XCTAssertFalse(clean.widgets.contains { $0.id == "approval" || $0.id == "drifted" })
    }

    func testTheMainButtonSwitchesAllOffThenTurnsAllBackOn() throws {
        let running = DebloatScreenBuilder.screen(snapshot([status(mainControl.id, .stock), status(helperControl.id, .debloated)]))
        XCTAssertEqual(running.primary?.id, "applyRecommended", "a verified feature still runs")
        XCTAssertEqual(running.primary?.role, .prominent)

        let allOff = DebloatScreenBuilder.screen(snapshot([status(mainControl.id, .debloated), status(helperControl.id, .debloated),
                                                           status(profileControl.id, .awaitingApproval)]))
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
        XCTAssertEqual(undone.widgets.first?.id, "drifted")
    }

    func testTile() {
        let none = DebloatScreenBuilder.tile(snapshot([]))
        XCTAssertEqual(none.status, "0/14 switched off")
        XCTAssertFalse(none.needsAttention)
        let drift = DebloatScreenBuilder.tile(snapshot([status(verifiedControl.id, .drifted)]))
        XCTAssertEqual(drift.status, "1 undone by macOS")
        XCTAssertTrue(drift.needsAttention)
        guard case let .dots(dots)? = drift.graphic else { return XCTFail() }
        XCTAssertEqual(dots.count, 14)
        XCTAssertEqual(dots.filter { $0 == .attention }.count, 1, "the undone control is the amber dot")
        XCTAssertEqual(DebloatScreenBuilder.tile(snapshot(offered.map { status($0.id, .debloated) })).status, "14/14 switched off")
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
