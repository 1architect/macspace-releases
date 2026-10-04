import XCTest
import MacSpaceSdk
import MacSpacePlatform
import MacSpaceSiriPrivileged
@testable import MacSpaceSiri

final class SiriScreenBuilderTests: XCTestCase {
    private func status(_ state: AppleIntelligenceGuardState, languagesMatch: Bool? = nil) -> AppleIntelligenceGuardStatus {
        AppleIntelligenceGuardStatus(generatedAt: Date(), state: state, ineligibilitySource: nil, languagesMatch: languagesMatch, eligible: state == .atRisk,
                                     targetSelected: nil, targetInstalled: nil,
                                     inputs: AppleIntelligenceGuardInputs(systemLanguage: "pt-BR", siriLanguage: "en-US", siriModeAnswer: nil, autoSetConfiguration: nil, installedTargetAssets: nil),
                                     reasons: ["r"])
    }

    private func plan() -> SiriLanguageChangePlan {
        SiriLanguageChangePlan(action: .disable, currentSiriLanguage: "pt-BR", targetSiriLanguage: "en-US", targetOutputVoice: nil, systemLanguage: "pt-BR",
                               scope: .thisMacOnly, scopeVerified: false, requiresSiriAssetDownload: nil, restoresSavedSettings: false, noChangeNeeded: false,
                               warnings: ["Apple Intelligence becomes unavailable.", "Siri is on: it will answer in en-US."])
    }

    private func snapshot(_ state: AppleIntelligenceGuardState, match: Bool? = nil, accounts: [AppleIntelligenceAccount]? = [],
                          purgeable: UInt64? = nil, blockers: [String] = []) -> SiriSnapshot {
        SiriSnapshot(status: status(state, languagesMatch: match), disablePlan: .success(plan()),
                     accounts: accounts.map { AppleIntelligenceAccountsReport(accounts: $0) }, purgeableAssetsBytes: purgeable,
                     releaseBlockers: blockers, watch: nil, cliPath: "/Applications/MacSpace.app/Contents/MacOS/MacSpaceCli", takenAt: Date())
    }

    private func other(_ name: String?) -> AppleIntelligenceAccount {
        AppleIntelligenceAccount(guid: "G-\(name ?? "gone")", name: name, isCurrentUser: false, useCases: ["x_isIFPEnabled_true_language_pt"])
    }

    func testVirtualMachineShowsOneExplanationAndNoControls() {
        var snap = snapshot(.unknown)
        snap.isVirtualMachine = true
        let screen = SiriScreenBuilder.screen(snap)
        XCTAssertEqual(screen.widgets.count, 1)
        guard case let .banner(banner) = screen.widgets[0] else { return XCTFail() }
        XCTAssertEqual(banner.title, "This is a virtual machine")
        XCTAssertEqual(SiriScreenBuilder.tile(snap).status, "not in a virtual machine")
    }

    func testBannerAndSwitchFollowTheState() {
        XCTAssertNil(SiriScreenBuilder.statusBanner(snapshot(.protected)), "nothing to do, so no banner")
        XCTAssertNil(SiriScreenBuilder.statusBanner(snapshot(.releasing)))
        XCTAssertNil(SiriScreenBuilder.statusBanner(snapshot(.atRisk)), "the switch itself says it is on")
        XCTAssertEqual(SiriScreenBuilder.statusBanner(snapshot(.unknown))?.action?.id, "openFullDiskAccess")
        XCTAssertTrue(SiriScreenBuilder.switchList(snapshot(.atRisk)).rows[0].subtitle?.hasPrefix("On.") == true)
        XCTAssertEqual(SiriScreenBuilder.switchList(snapshot(.atRisk)).rows[0].isOn, true)
        XCTAssertEqual(SiriScreenBuilder.switchList(snapshot(.protected)).rows[0].isOn, false)
        XCTAssertEqual(SiriScreenBuilder.switchList(snapshot(.unknown, match: true)).rows[0].isOn, true, "unknown falls back to the language match")
    }

    func testSwitchNeverAsksAndNeedsFullDiskAccess() throws {
        let off = try XCTUnwrap(SiriScreenBuilder.switchList(snapshot(.atRisk)).rows.first)
        XCTAssertNil(off.action.confirmation, "the switch moves at once; a failure moves it back")
        XCTAssertTrue(off.detail?.contains("iPhone and iPad") == true, "says where the Siri language goes")
        XCTAssertEqual(off.action.requires, [.fullDiskAccess], "the result cannot be verified without it")
        let on = try XCTUnwrap(SiriScreenBuilder.switchList(snapshot(.protected)).rows.first)
        XCTAssertNil(on.action.confirmation)
    }

    func testICloudSyncSwitchShowsTheLiveSetting() throws {
        var synced = snapshot(.protected)
        synced.cloudSyncOn = true
        let row = try XCTUnwrap(SiriScreenBuilder.switchList(synced).rows.first { $0.id == "icloud-sync" })
        XCTAssertTrue(row.isOn)
        XCTAssertEqual(row.action.id, "cloudSync")
        XCTAssertNil(row.action.confirmation)
        XCTAssertNil(SiriScreenBuilder.switchList(snapshot(.protected)).rows.first { $0.id == "icloud-sync" }, "no switch when the setting cannot be read")
    }

    func testModelsBeingDownloadedAreNeverNoModel() {
        var downloading = snapshot(.atRisk)
        downloading.installedModelBytes = 0
        downloading.downloadingModelBytes = 2_000_000_000
        XCTAssertTrue(SiriScreenBuilder.modelLine(downloading).contains("downloading"))
        XCTAssertFalse(SiriScreenBuilder.tile(downloading).graphic.map { "\($0)".contains("no model downloaded yet") } ?? true)
        var unreadable = snapshot(.atRisk)
        unreadable.installedModelBytes = nil
        XCTAssertTrue(SiriScreenBuilder.modelLine(unreadable).contains("could not be measured"))
    }

    func testTileFlagsAppleIntelligenceWhenItIsOn() {
        let on = SiriScreenBuilder.tile(snapshot(.atRisk))
        XCTAssertEqual(on.status, "AI is on")
        XCTAssertTrue(on.needsAttention)
        let off = SiriScreenBuilder.tile(snapshot(.protected))
        XCTAssertEqual(off.status, "AI is off")
        XCTAssertFalse(off.needsAttention)
        XCTAssertTrue(SiriScreenBuilder.tile(snapshot(.protected, accounts: [other("tester")])).needsAttention, "another account keeps the models")
    }

    func testTileShowsTheDownloadedModelsAsFreeableAndDoesNotGlow() {
        var on = snapshot(.atRisk)
        on.installedModelBytes = 12_000_000_000
        let tile = SiriScreenBuilder.tile(on)
        XCTAssertEqual(tile.reclaimableBytes, 12_000_000_000, "switching it off frees them")
        XCTAssertTrue(tile.status.hasSuffix("can be freed"))
        guard case let .state(isOn, alarming, detail, _, _)? = tile.graphic else { return XCTFail() }
        XCTAssertTrue(isOn)
        XCTAssertFalse(alarming, "no glow")
        XCTAssertFalse(detail.contains("may download"))
        XCTAssertTrue(SiriScreenBuilder.stateLine(on).contains("switch it off to free them"))

        on.installedModelBytes = 0
        XCTAssertEqual(SiriScreenBuilder.tile(on).status, "AI is on")
        XCTAssertEqual(SiriScreenBuilder.stateLine(on), "On. No model is downloaded yet.")
        XCTAssertNil(SiriScreenBuilder.tile(snapshot(.protected)).reclaimableBytes, "off with nothing left: nothing to free")
    }

    func testOtherAccountsExplainWhatToDo() throws {
        let snap = snapshot(.protected, accounts: [other("tester"), other(nil)])
        XCTAssertEqual(SiriScreenBuilder.statusBanner(snap)?.severity, .warning)
        XCTAssertTrue(SiriScreenBuilder.statusBanner(snap)?.title.contains("Still installed") == true)
        guard case let .section(section)? = SiriScreenBuilder.accountsSection(snap), case let .list(list) = section.widgets[0] else { return XCTFail() }
        XCTAssertEqual(list.rows.count, 2)
        XCTAssertTrue(list.rows[0].steps[0].contains("Log in as tester"))
        XCTAssertTrue(list.rows[1].steps.contains { $0.contains("sudo") && $0.contains("MacSpaceCli") && $0.contains("orphan-subscriptions --execute") })
        XCTAssertNil(SiriScreenBuilder.accountsSection(snapshot(.protected)), "no section when nothing else holds the models")
        XCTAssertNil(SiriScreenBuilder.accountsSection(snapshot(.protected, accounts: nil)))
    }

    func testPurgeIsTheMainActionAndModelsReleaseThemselves() throws {
        func widgets(_ snap: SiriSnapshot) -> [ScreenWidget] {
            guard case let .section(section)? = SiriScreenBuilder.modelsSection(snap) else { return [] }
            return section.widgets
        }
        let ready = snapshot(.protected, purgeable: 12_000_000_000)
        let purge = try XCTUnwrap(SiriScreenBuilder.screen(ready).primary)
        XCTAssertEqual(purge.id, "purgeAssets")
        XCTAssertNotNil(purge.confirmation)
        XCTAssertNil(SiriScreenBuilder.modelsSection(ready), "nothing left over once macOS has let go of the model")

        guard case let .list(waiting)? = widgets(snapshot(.releasing)).first else { return XCTFail() }
        XCTAssertTrue(waiting.rows[0].actions.isEmpty, "no button: MacSpace releases them by itself")
        var running = snapshot(.protected)
        running.releasingAutomatically = true
        guard case let .list(releasing)? = widgets(running).first else { return XCTFail() }
        XCTAssertEqual(releasing.rows[0].title, "Releasing the leftover models")

        guard case let .steps(steps)? = widgets(snapshot(.releasing, blockers: ["Apple Intelligence is on in tester."])).first else { return XCTFail() }
        XCTAssertEqual(steps.steps, ["Apple Intelligence is on in tester."])
        XCTAssertNil(SiriScreenBuilder.screen(snapshot(.protected, purgeable: 1_000)).primary, "a few KB is not worth a button")
        XCTAssertNil(SiriScreenBuilder.modelsSection(snapshot(.atRisk)), "nothing to release while Apple Intelligence is on")
    }

    func testAutoReleaseWaitsForMacOSAndDoesNotRepeat() {
        let now = Date()
        func due(_ state: AppleIntelligenceGuardState = .releasing, blockers: [String] = [], since: TimeInterval? = 11 * 60,
                 last: TimeInterval? = nil, vm: Bool = false) -> Bool {
            ModelAutoRelease.shouldRun(state: state, blockers: blockers, isVirtualMachine: vm,
                                       releasingSince: since.map { now.addingTimeInterval(-$0) },
                                       lastRun: last.map { now.addingTimeInterval(-$0) }, now: now)
        }
        XCTAssertTrue(due())
        XCTAssertFalse(due(since: 60), "macOS usually removes the model by itself within minutes")
        XCTAssertFalse(due(since: nil))
        XCTAssertFalse(due(.protected))
        XCTAssertFalse(due(.atRisk))
        XCTAssertFalse(due(blockers: ["another account"]))
        XCTAssertFalse(due(vm: true))
        XCTAssertFalse(due(last: 60 * 60), "once in twelve hours at most")
        XCTAssertTrue(due(last: 13 * 60 * 60))
    }

    func testScreenContainsEverySectionInOrder() {
        var snap = snapshot(.protected, accounts: [other("tester")], purgeable: 1_000_000_000)
        snap.releasingAutomatically = true
        let screen = SiriScreenBuilder.screen(snap)
        XCTAssertEqual(screen.widgets.map(\.id), ["status", "switch", "accounts", "models"])
    }
}
