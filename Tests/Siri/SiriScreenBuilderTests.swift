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
        guard case let .banner(tile) = SiriScreenBuilder.summary(snap) else { return XCTFail() }
        XCTAssertNil(tile.action, "nothing to switch off in a virtual machine")
    }

    func testBannerAndSwitchFollowTheState() {
        XCTAssertEqual(SiriScreenBuilder.statusBanner(snapshot(.protected)).severity, .success)
        XCTAssertEqual(SiriScreenBuilder.statusBanner(snapshot(.releasing)).severity, .info)
        XCTAssertEqual(SiriScreenBuilder.statusBanner(snapshot(.atRisk)).severity, .warning)
        XCTAssertTrue(SiriScreenBuilder.statusBanner(snapshot(.unknown)).message?.contains("Full Disk Access") == true)
        XCTAssertEqual(SiriScreenBuilder.switchList(snapshot(.atRisk)).rows[0].isOn, true)
        XCTAssertEqual(SiriScreenBuilder.switchList(snapshot(.protected)).rows[0].isOn, false)
        XCTAssertEqual(SiriScreenBuilder.switchList(snapshot(.unknown, match: true)).rows[0].isOn, true, "unknown falls back to the language match")
    }

    func testSwitchAlwaysAsksBeforeChangingAndNeedsFullDiskAccess() throws {
        let off = try XCTUnwrap(SiriScreenBuilder.switchList(snapshot(.atRisk)).rows.first)
        XCTAssertTrue(off.action.confirmation?.message.contains("pt-BR to en-US") == true)
        XCTAssertFalse(off.action.confirmation?.message.contains("Whether this preference syncs") == true)
        XCTAssertEqual(off.action.requires, [.fullDiskAccess], "the result cannot be verified without it")
        let on = try XCTUnwrap(SiriScreenBuilder.switchList(snapshot(.protected)).rows.first)
        XCTAssertEqual(on.action.confirmation?.confirmTitle, "Turn on")
    }

    func testSummaryOffersTheSwitchOnlyWhenAppleIntelligenceIsOn() {
        guard case let .banner(on) = SiriScreenBuilder.summary(snapshot(.atRisk)), case let .banner(off) = SiriScreenBuilder.summary(snapshot(.protected)) else { return XCTFail() }
        XCTAssertEqual(on.action?.parameters, ["id": "ai", "value": "false"])
        XCTAssertNil(off.action)
    }

    func testOtherAccountsExplainWhatToDo() throws {
        let snap = snapshot(.protected, accounts: [other("tester"), other(nil)])
        XCTAssertEqual(SiriScreenBuilder.statusBanner(snap).severity, .warning)
        XCTAssertTrue(SiriScreenBuilder.statusBanner(snap).title.contains("still installed"))
        guard case let .section(section)? = SiriScreenBuilder.accountsSection(snap), case let .list(list) = section.widgets[0] else { return XCTFail() }
        XCTAssertEqual(list.rows.count, 2)
        XCTAssertTrue(list.rows[0].steps[0].contains("Log in as tester"))
        XCTAssertTrue(list.rows[1].steps.contains { $0.contains("sudo") && $0.contains("MacSpaceCli") && $0.contains("orphan-subscriptions --execute") })
        XCTAssertNil(SiriScreenBuilder.accountsSection(snapshot(.protected)), "no section when nothing else holds the models")
        XCTAssertNil(SiriScreenBuilder.accountsSection(snapshot(.protected, accounts: nil)))
    }

    func testModelsSectionShowsPurgeOrReleaseOrWhatBlocksThem() throws {
        func widgets(_ snap: SiriSnapshot) -> [ScreenWidget] {
            guard case let .section(section) = SiriScreenBuilder.modelsSection(snap) else { return [] }
            return section.widgets
        }
        let ready = widgets(snapshot(.protected, purgeable: 12_000_000_000))
        guard case let .button(purge) = ready[0], case let .button(release) = ready[1] else { return XCTFail() }
        XCTAssertEqual(purge.action.id, "purgeAssets")
        XCTAssertNotNil(purge.action.confirmation)
        XCTAssertEqual(release.action.id, "releaseModels")
        XCTAssertNotNil(release.action.confirmation, "the release flips the Siri language for a minute, so it asks first")

        let blocked = widgets(snapshot(.protected, blockers: ["Apple Intelligence is on in tester."]))
        guard case .text = blocked[0], case let .steps(steps) = blocked[1] else { return XCTFail() }
        XCTAssertEqual(steps.steps, ["Apple Intelligence is on in tester."])
        guard case .text = widgets(snapshot(.protected, purgeable: 1_000))[0] else { return XCTFail("a few KB is not worth a button") }
    }

    func testScreenContainsEverySectionInOrder() {
        let screen = SiriScreenBuilder.screen(snapshot(.protected, accounts: [other("tester")], purgeable: 1_000_000_000))
        XCTAssertEqual(screen.widgets.map(\.id), ["status", "switch", "accounts", "models"])
    }
}
