import XCTest
import MacSpaceSdk
import MacSpacePlatform
@testable import MacSpaceDebloat
@testable import MacSpaceDebloatPrivileged

final class DebloatScreenBuilderTests: XCTestCase {
    private let helperControl = DebloatCatalog.control("diagnostics.tailspin")!
    private let profileControl = DebloatCatalog.control("ads.personalized-ads-policy")!
    private let verifiedControl = DebloatCatalog.control("telemetry.diagnostics-policy")!

    private func status(_ id: String, _ state: ControlState, validated: Bool = false, effect: EffectStatus? = nil) -> ControlStatus {
        ControlStatus(controlID: id, state: state, effect: effect, settings: [], validatedOnThisBuild: validated, appliedAt: nil)
    }

    private func snapshot(_ statuses: [ControlStatus], blocked: Set<String> = []) -> DebloatSnapshot {
        DebloatSnapshot(controls: DebloatCatalog.controls, statuses: Dictionary(uniqueKeysWithValues: statuses.map { ($0.controlID, $0) }),
                        environment: DebloatEnvironment(productVersion: "27.2", build: "26B5091g", isPrerelease: true, sip: .enabled, mdmEnrolled: false, depEnrolled: false, architecture: "arm64", userName: "u", uid: 501, runningAsRoot: false, fullDiskAccess: true),
                        cannotTakeEffect: blocked, takenAt: Date())
    }

    func testEveryControlGetsOneToggleInItsCategory() {
        let screen = DebloatScreenBuilder.screen(snapshot([]))
        var ids: [String] = []
        for case let .toggles(list) in screen.widgets { ids += list.rows.map(\.id) }
        XCTAssertEqual(Set(ids), Set(DebloatCatalog.controls.map(\.id)))
        XCTAssertEqual(ids.count, DebloatCatalog.controls.count)
    }

    func testToggleStateBadgeAndConfirmationFollowTheControlState() {
        let on = DebloatScreenBuilder.row(verifiedControl, snapshot([status(verifiedControl.id, .debloated, validated: true,
                                                                            effect: EffectStatus(state: .effective, detail: "no submissions"))]))
        XCTAssertTrue(on.isOn)
        XCTAssertEqual(on.badge?.text, "Verified working")
        XCTAssertEqual(on.action.confirmation?.confirmTitle, "Turn off", "an applied control is turned off")

        let off = DebloatScreenBuilder.row(verifiedControl, snapshot([status(verifiedControl.id, .stock, validated: true)]))
        XCTAssertFalse(off.isOn)
        XCTAssertEqual(off.badge?.text, "Recommended")
        XCTAssertEqual(off.action.confirmation?.confirmTitle, "Turn on")
        XCTAssertEqual(off.action.parameters["unverified"], "false")

        let unverified = DebloatScreenBuilder.row(profileControl, snapshot([status(profileControl.id, .stock)]))
        XCTAssertEqual(unverified.badge?.text, "Not verified on this macOS")
        XCTAssertEqual(unverified.action.parameters["unverified"], "true")
        XCTAssertTrue(unverified.action.confirmation?.message.contains("not verified") == true)
        XCTAssertTrue(unverified.action.confirmation?.message.contains("approve the MACSPACE profile") == true)
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
        XCTAssertTrue(waiting.isOn, "applied, waiting only for the user's approval")
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
            status(verifiedControl.id, .stock, validated: true), status(helperControl.id, .stock, validated: true),
            status(profileControl.id, .awaitingApproval), status("ads.advertising-identifier-policy", .drifted),
        ]))
        XCTAssertEqual(screen.widgets.map(\.id).prefix(4), ["approval", "drifted", "recommended", "cat:telemetry"])
        guard case let .button(button) = screen.widgets[2] else { return XCTFail() }
        XCTAssertEqual(Set(button.action.parameters["ids"]?.split(separator: ",").map(String.init) ?? []), [verifiedControl.id, helperControl.id])
        XCTAssertNotNil(button.action.confirmation)

        let clean = DebloatScreenBuilder.screen(snapshot([]))
        XCTAssertFalse(clean.widgets.contains { $0.id == "approval" || $0.id == "drifted" || $0.id == "recommended" })
    }

    func testSummaryTile() {
        guard case let .banner(none) = DebloatScreenBuilder.summary(snapshot([])),
              case let .banner(drift) = DebloatScreenBuilder.summary(snapshot([status(verifiedControl.id, .drifted)])),
              case let .banner(all) = DebloatScreenBuilder.summary(snapshot(DebloatCatalog.controls.map { status($0.id, .debloated) })) else { return XCTFail() }
        XCTAssertEqual(none.title, "0 of 14 protections are on")
        XCTAssertEqual(drift.severity, .warning)
        XCTAssertEqual(all.title, "14 of 14 protections are on")
        XCTAssertEqual(all.severity, .success)
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
