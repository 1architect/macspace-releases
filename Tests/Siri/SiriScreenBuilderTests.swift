import XCTest
import MacSpaceSdk
import MacSpacePlatform
import MacSpaceSiriPrivileged
@testable import MacSpaceSiri

final class SiriScreenBuilderTests: XCTestCase {
    func testPhoneSwitchUsesRequestedStateDuringRestartAndCanRestoreOnAnUnreviewedRelease() {
        let offPending = PhoneFeatureFlags.Status(state: .restartRequired, managedOff: false, effective: [:], requestedOff: true)
        let off = SiriScreenBuilder.phoneFeatureRow(offPending)
        XCTAssertFalse(off.isOn)
        XCTAssertTrue(off.isEnabled)
        XCTAssertNotNil(off.badge)
        XCTAssertNil(off.action.confirmation)
        XCTAssertEqual(off.action.requires, [.privilegedHelper])
        let on = SiriScreenBuilder.phoneFeatureRow(.init(state: .restartRequired, managedOff: false, effective: [:], requestedOff: false))
        XCTAssertTrue(on.isOn)
        XCTAssertTrue(SiriScreenBuilder.phoneFeatureRow(.init(state: .unsupported, managedOff: false, effective: [:], requestedOff: true)).isEnabled)
        XCTAssertFalse(SiriScreenBuilder.phoneFeatureRow(.init(state: .unsupported, managedOff: false, effective: [:])).isEnabled)
        XCTAssertFalse(SiriScreenBuilder.phoneFeatureRow(.init(state: .changedElsewhere, managedOff: false, effective: [:], requestedOff: true)).isEnabled)
        XCTAssertFalse(SiriScreenBuilder.phoneFeatureRow(.init(state: .off, managedOff: false, effective: [:], requestedOff: false)).isOn,
                       "Restoring originally disabled gates must not report that features are on")
    }

    func testPhoneChangeReconcilesOnlyItsSwitchAndRetainsMeasurements() async throws {
        var fixture = snapshot(.protected, purgeable: 123_456_789)
        fixture.installedModelBytes = 987_654_321
        fixture.phoneFeatures = .init(state: .on, managedOff: false, effective: [:])
        let before = fixture
        let reads = SnapshotReads()
        let store = SiriStore(builder: { _ in _ = reads.next(); return before })
        _ = await store.snapshot()
        let changed = PhoneFeatureFlags.Status(state: .off, managedOff: true, effective: [:], requestedOff: true)
        let updated = await store.reconcilePhoneFeatures(read: { changed })
        XCTAssertEqual(updated?.phoneFeatures, changed)
        XCTAssertEqual(updated?.status, before.status)
        XCTAssertEqual(updated?.installedModelBytes, before.installedModelBytes)
        XCTAssertEqual(updated?.purgeableAssetsBytes, before.purgeableAssetsBytes)
        XCTAssertEqual(updated?.takenAt, before.takenAt)
        XCTAssertEqual(reads.total, 1)
        let cached = await store.snapshot(maxAge: .infinity)
        XCTAssertEqual(cached.phoneFeatures, changed)
        XCTAssertEqual(reads.total, 1)
    }

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

    func testStoreSharesProgressWithPageJoiningTileAndKeepsCachedReadsQuiet() async throws {
        let fixture = snapshot(.atRisk)
        let reads = SnapshotReads()
        let started = expectation(description: "scan started")
        let joined = expectation(description: "page joined current scan")
        let release = DispatchSemaphore(value: 0)
        let heard = LoadProgressRelay()
        let store = SiriStore(builder: { progress in
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
        XCTAssertEqual(SiriScreenBuilder.statusBanner(snapshot(.unknown))?.action?.id, Action.fullDiskAccessID)
        XCTAssertEqual(SiriScreenBuilder.switchList(snapshot(.atRisk)).rows[0].isOn, true)
        XCTAssertEqual(SiriScreenBuilder.switchList(snapshot(.protected)).rows[0].isOn, false)
        XCTAssertEqual(SiriScreenBuilder.switchList(snapshot(.unknown, match: true)).rows[0].isOn, true, "unknown falls back to the language match")
    }

    func testFeatureSwitchesKeepTheirOwnStateAndReuseTheExistingToggleRows() {
        var snap = snapshot(.protected)
        snap.featureSettings = [.siri: .init(state: .off, managedOff: true, requestedOff: true),
                                .spatialPhotos: .init(state: .on), .phone: .init(state: .on)]
        snap.phoneFeatures = .init(state: .off, managedOff: true, effective: [:], requestedOff: true)
        let rows = SiriScreenBuilder.switchList(snap).rows
        XCTAssertEqual(rows.map(\.id), ["ai", "siri", "spatialPhotos", "phone"])
        XCTAssertFalse(rows[0].isOn)
        XCTAssertFalse(rows[1].isOn)
        XCTAssertTrue(rows[2].isOn)
        XCTAssertTrue(rows[3].isOn, "disabled root flags alone must not pretend that native Phone controls are off")
        XCTAssertEqual(rows[1].action.parameters["feature"], "siri")
        XCTAssertNil(rows[1].action.confirmation)
        XCTAssertNil(rows[2].action.confirmation)
    }

    func testFeatureModelsCountOnTheTileAndUnderTheirSwitchLikeTheAppleIntelligenceModels() {
        var snap = snapshot(.protected)
        snap.installedModelBytes = 0
        snap.featureSettings = [.siri: .init(state: .on), .spatialPhotos: .init(state: .on)]
        snap.featureModelBytes = [.siri: 2_400_000_000, .spatialPhotos: 800_000_000]
        let tile = SiriScreenBuilder.tile(snap)
        XCTAssertEqual(tile.reclaimableBytes, 3_200_000_000)
        XCTAssertTrue(tile.needsAttention, "on with models on disk, as Apple Intelligence on")
        guard case let .state(_, _, detail, _, _) = tile.graphic else { return XCTFail() }
        XCTAssertTrue(detail.contains("Siri features"), detail)
        let rows = SiriScreenBuilder.switchList(snap).rows
        XCTAssertEqual(rows[1].trailing, ByteFormat.string(2_400_000_000))
        snap.featureDownloading = [.spatialPhotos]
        XCTAssertEqual(SiriScreenBuilder.refreshAfter(snap), 5, "a download is followed as it arrives")
        snap.featureSettings = [.siri: .init(state: .off, managedOff: true, requestedOff: true), .spatialPhotos: .init(state: .off, managedOff: true, requestedOff: true)]
        XCTAssertNil(SiriScreenBuilder.tile(snap).reclaimableBytes, "switched off, the models are MacSpace's to delete, not the user's to free")
        snap.featureDownloading = []
        guard case let .state(_, _, kept, _, _) = SiriScreenBuilder.tile(snap).graphic else { return XCTFail() }
        XCTAssertEqual(kept, "\(ByteFormat.string(3_200_000_000)) of models kept by macOS", "never said clean while they stay")
        XCTAssertEqual(SiriScreenBuilder.switchList(snap).rows[1].trailing, ByteFormat.string(2_400_000_000))
        snap.featureCleanupWaiting = [.siri]
        guard case let .state(_, _, deleting, _, _) = SiriScreenBuilder.tile(snap).graphic else { return XCTFail() }
        XCTAssertEqual(deleting, "deleting \(ByteFormat.string(3_200_000_000)) of models")
    }

    func testEveryInfoTextIsStaticAndShortInEveryState() {
        var texts: Set<String>?
        for state in [AppleIntelligenceGuardState.atRisk, .protected, .releasing, .unknown] {
            for phone in [PhoneFeatureFlags.State.on, .off, .restartRequired, .changedElsewhere, .unknown, .unsupported] {
                for cloud in [true, false, nil] as [Bool?] {
                    var snap = snapshot(state)
                    snap.cloudSyncEnabled = cloud
                    snap.featureSettings = [.siri: .init(state: .on), .spatialPhotos: .init(state: .off, managedOff: true, requestedOff: true)]
                    snap.phoneFeatures = .init(state: phone, managedOff: false, effective: [:])
                    let screen = SiriScreenBuilder.screen(snap)
                    XCTAssertEqual(InfoText.violations(in: screen), [])
                    let switches = Set(SiriScreenBuilder.switchList(snap).rows.compactMap(\.detail) + [SiriScreenBuilder.cloudSyncRow(enabled: cloud).detail].compactMap { $0 })
                    if let texts { XCTAssertEqual(switches, texts, "the (i) does not change with the state") } else { texts = switches }
                }
            }
        }
    }

    func testModelsOnlyARestartFreesAskForOneThroughMacOSsDialog() throws {
        var snap = snapshot(.protected)
        snap.featureSettings = [.siri: .init(state: .off, managedOff: true, requestedOff: true)]
        snap.featureModelBytes = [.siri: 1_400_000_000]
        snap.featureCleanupWaiting = [.siri]
        XCTAssertEqual(SiriScreenBuilder.switchList(snap).rows[1].badge?.role, .freeingInBackground, "not held: MacSpace deletes them again")
        XCTAssertNotEqual(SiriScreenBuilder.screen(snap).primary?.id, Action.restartID)
        snap.featureLocked = [.siri]
        XCTAssertEqual(SiriScreenBuilder.switchList(snap).rows[1].badge?.role, .freeingInBackground, "a lock alone: macOS usually lets go within minutes")
        XCTAssertNotEqual(SiriScreenBuilder.screen(snap).primary?.id, Action.restartID)
        snap.featureCleanupStalled = [.siri]
        XCTAssertEqual(SiriScreenBuilder.switchList(snap).rows[1].badge?.text, "Restart required")
        XCTAssertEqual(SiriScreenBuilder.switchList(snap).rows[1].badge?.kind, .action)
        snap.featureDownloading = [.siri]
        XCTAssertNotEqual(SiriScreenBuilder.screen(snap).primary?.id, Action.restartID, "macOS downloading again: a restart does not stop it")
        snap.featureDownloading = []
        let restart = try XCTUnwrap(SiriScreenBuilder.screen(snap).primary)
        XCTAssertEqual(restart.id, Action.restartID)
        XCTAssertEqual(restart.title, "Restart to free \(ByteFormat.string(1_400_000_000))")
        XCTAssertNil(restart.confirmation, "macOS's own Restart dialog asks")
    }

    /// While a switched-off feature's models are on disk, the page's Free is theirs, with the figure their rows show, before the purge
    /// of every unused system asset (whose estimate is another figure).
    func testThePagesFreeIsTheSwitchedOffFeaturesModels() throws {
        var snap = snapshot(.protected, purgeable: 182_800_000)
        snap.featureSettings = [.spatialPhotos: .init(state: .off, managedOff: true, requestedOff: true)]
        snap.phoneFeatures = .init(state: .off, managedOff: true, effective: [:], requestedOff: true)
        snap.featureModelBytes = [.phone: 371_400_000, .spatialPhotos: 100_000_000]
        let free = try XCTUnwrap(SiriScreenBuilder.screen(snap).primary)
        XCTAssertEqual(free.id, "freeFeatureModels")
        XCTAssertEqual(free.title, "Free \(ByteFormat.string(471_400_000))")
        snap.featureCleanupWaiting = [.phone, .spatialPhotos]
        XCTAssertNotEqual(SiriScreenBuilder.screen(snap).primary?.id, "freeFeatureModels", "being freed: no button can hurry macOS")
        XCTAssertNotEqual(SiriScreenBuilder.screen(snap).primary?.id, "purgeAssets")
        XCTAssertEqual(SiriScreenBuilder.switchList(snap).rows.last?.badge?.role, .freeingInBackground)
        snap.featureCleanupWaiting = []
        snap.cleaningFeatures = true
        snap.featureSettings[.siri] = .init(state: .off, managedOff: true, requestedOff: true)
        XCTAssertNil(SiriScreenBuilder.switchList(snap).rows[1].badge, "no models on disk: no Freeing pill")
        snap.cleaningFeatures = false
        snap.featureSettings[.siri] = nil
        snap.featureDownloading = [.phone, .spatialPhotos]
        XCTAssertEqual(SiriScreenBuilder.screen(snap).primary?.id, "purgeAssets", "being downloaded again: nothing to delete yet")
        snap.featureDownloading = []
        snap.featureModelBytes = [.phone: 16_000_000]
        XCTAssertEqual(SiriScreenBuilder.screen(snap).primary?.id, "purgeAssets", "freed: the purge of unused assets comes back")
    }

    /// A download comes in pieces: the switch keeps saying Downloading between them.
    func testDownloadingLingersBetweenPieces() {
        let sightings = DownloadSightings()
        let now = Date()
        XCTAssertFalse(sightings.downloading(.phone, seenNow: false, now: now))
        XCTAssertTrue(sightings.downloading(.phone, seenNow: true, now: now))
        XCTAssertTrue(sightings.downloading(.phone, seenNow: false, now: now.addingTimeInterval(10)))
        XCTAssertFalse(sightings.downloading(.phone, seenNow: false, now: now.addingTimeInterval(31)))
    }

    func testNoRestartIsAskedForAFeatureThatIsOn() {
        var snap = snapshot(.protected)
        snap.featureSettings = [.siri: .init(state: .on)]
        snap.featureModelBytes = [.siri: 72_600_000]
        snap.featureCleanupWaiting = [.siri]
        snap.featureLocked = [.siri]
        XCTAssertNotEqual(SiriScreenBuilder.screen(snap).primary?.id, Action.restartID, "on, it keeps its models")
        XCTAssertNotEqual(SiriScreenBuilder.switchList(snap).rows[1].badge?.text, "Restart required")
    }

    func testTheTileSwitchIsOnWhileAnySwitchIsAndSetsThemAll() throws {
        var snap = snapshot(.protected)
        snap.featureSettings = [.siri: .init(state: .on), .spatialPhotos: .init(state: .off)]
        let tile = SiriScreenBuilder.tile(snap)
        guard case let .state(on, _, _, _, _)? = tile.graphic else { return XCTFail() }
        XCTAssertTrue(on, "Siri is on, though Apple Intelligence is off")
        let action = try XCTUnwrap(tile.switchAction)
        XCTAssertEqual(action.id, "setAll")
        XCTAssertEqual(action.parameters["on"], "siri")
        XCTAssertEqual(action.parameters["off"], "ai,spatialPhotos")
        snap.featureSettings = [.siri: .init(state: .off), .spatialPhotos: .init(state: .off)]
        guard case let .state(allOff, _, _, _, _)? = SiriScreenBuilder.tile(snap).graphic else { return XCTFail() }
        XCTAssertFalse(allOff)
    }

    func testTheListsAreTitled() {
        let screen = SiriScreenBuilder.screen(snapshot(.protected))
        var titles: [String] = []
        for widget in screen.widgets {
            if case let .toggles(list) = widget { titles.append(list.title ?? "") }
            if case let .list(list) = widget { titles.append(list.title ?? "") }
        }
        XCTAssertEqual(titles, ["Models", "Sync to other devices"])
    }

    func testQuietTileNeitherFlagsNorGrowsForModelsASwitchWouldFree() {
        var snap = snapshot(.atRisk)
        snap.installedModelBytes = 12_000_000_000
        snap.featureSettings = [.siri: .init(state: .on)]
        snap.featureModelBytes = [.siri: 2_400_000_000]
        XCTAssertTrue(SiriScreenBuilder.tile(snap).needsAttention)
        XCTAssertNotNil(SiriScreenBuilder.tile(snap).reclaimableBytes)
        snap.flagsModels = false
        XCTAssertFalse(SiriScreenBuilder.tile(snap).needsAttention, "no mark")
        XCTAssertNil(SiriScreenBuilder.tile(snap).reclaimableBytes, "not the Home page's large tile")
        snap.purgeableAssetsBytes = 3_000_000_000
        XCTAssertEqual(SiriScreenBuilder.tile(snap).reclaimableBytes, 3_000_000_000, "what Free deletes still counts")
    }

    func testMainButtonDisablesEverySwitchStillOnThenEnablesThemAgain() throws {
        var snap = snapshot(.atRisk)
        snap.featureSettings = [.siri: .init(state: .on), .spatialPhotos: .init(state: .off)]
        let disable = try XCTUnwrap(SiriScreenBuilder.screen(snap).primary)
        XCTAssertEqual(disable.id, "disableAll")
        XCTAssertEqual(disable.parameters["ids"], "ai,siri")
        XCTAssertNotNil(disable.confirmation)
        snap.status = status(.protected, languagesMatch: nil)
        snap.featureSettings = [.siri: .init(state: .off), .spatialPhotos: .init(state: .off)]
        let enable = try XCTUnwrap(SiriScreenBuilder.screen(snap).primary)
        XCTAssertEqual(enable.id, "enableAll")
        XCTAssertEqual(enable.parameters["ids"], "ai,siri,spatialPhotos")
        XCTAssertEqual(SiriScreenBuilder.screen(self.snapshot(.protected, purgeable: 12_000_000_000)).primary?.id, "purgeAssets", "freeing comes first")
    }

    func testFeatureCleanupUsesTheStandardBadgeAndFastStatusPolling() {
        var snap = snapshot(.protected)
        snap.featureSettings = [.siri: .init(state: .off, managedOff: true, requestedOff: true)]
        snap.cleaningFeatures = true
        snap.featureModelBytes = [.siri: 1_400_000_000]
        XCTAssertEqual(SiriScreenBuilder.switchList(snap).rows[1].badge?.role, .freeingInBackground)
        XCTAssertEqual(SiriScreenBuilder.refreshAfter(snap), 5)
        snap.cleaningFeatures = false
        snap.featureCleanupWaiting = [.siri]
        XCTAssertEqual(SiriScreenBuilder.switchList(snap).rows[1].badge?.role, .freeingInBackground)
        XCTAssertNil(SiriScreenBuilder.switchList(snap).rows[1].badge?.help, "nothing holds them up: no tag")
        snap.featureLocked = [.siri]
        XCTAssertEqual(SiriScreenBuilder.switchList(snap).rows[1].badge?.role, .freeingInBackground)
        XCTAssertTrue(SiriScreenBuilder.switchList(snap).rows[1].badge?.help?.contains("services") == true, "says what holds them")
        snap.featureModelBytes = [.siri: 9_000_000]
        XCTAssertNil(SiriScreenBuilder.switchList(snap).rows[1].badge, "nothing worth a size is left: no pill")
    }

    func testPhoneSwitchPreservesNativeWarningsInsteadOfReportingEveryMismatchAsUnknown() throws {
        var snap = snapshot(.protected)
        snap.phoneFeatures = .init(state: .off, managedOff: true, effective: [:], requestedOff: true)
        let cases: [(ModelFeatureSettings.State, String?)] = [
            (.off, nil), (.changedElsewhere, "Changed outside MacSpace"),
            (.unknown, "State unknown"), (.unsupported, "Not verified on this macOS version")
        ]
        for (state, badge) in cases {
            snap.featureSettings = [.phone: .init(state: state, managedOff: state == .off, requestedOff: true)]
            let row = try XCTUnwrap(SiriScreenBuilder.switchList(snap).rows.last)
            XCTAssertEqual(row.id, "phone")
            XCTAssertFalse(row.isOn)
            XCTAssertEqual(row.badge?.text, badge, "state: \(state)")
            if state == .off { XCTAssertTrue(row.isEnabled) }
            XCTAssertEqual(row.detail, SiriScreenBuilder.phoneFeatureRow(.init(state: .on, managedOff: false, effective: [:])).detail,
                           "the state is the badge, never the (i)")
        }
    }

    func testSwitchNeverAsksAndNeedsFullDiskAccess() throws {
        let off = try XCTUnwrap(SiriScreenBuilder.switchList(snapshot(.atRisk)).rows.first)
        XCTAssertNil(off.action.confirmation, "the switch moves at once; a failure moves it back")
        XCTAssertTrue(off.detail?.contains("iPhone and iPad") == true, "says where the Siri language goes")
        XCTAssertEqual(off.action.requires, [.fullDiskAccess], "the result cannot be verified without it")
        let on = try XCTUnwrap(SiriScreenBuilder.switchList(snapshot(.protected)).rows.first)
        XCTAssertNil(on.action.confirmation)
    }

    /// MacSpace cannot change Siri's iCloud sync (an iCloud account data class only System Settings may set): the page says what it
    /// does and opens the setting, with no switch that would pretend to change it.
    func testICloudSyncIsAGuideToSystemSettingsNotASwitch() throws {
        let screen = SiriScreenBuilder.screen(snapshot(.protected))
        var toggleIDs: [String] = []
        for case let .toggles(list) in screen.widgets { toggleIDs += list.rows.map(\.id) }
        XCTAssertFalse(toggleIDs.contains("icloud-sync"))
        let row = SiriScreenBuilder.cloudSyncRow(enabled: true)
        XCTAssertEqual(row.actions.map(\.id), [Action.openSettingsID], "the app opens System Settings")
        XCTAssertEqual(row.actions.first.flatMap { Action.settingsPane($0.parameters) }, SiriCloudSync.settingsURL)
        XCTAssertTrue(row.steps.contains { $0.contains("Sync this Mac") })
        let off = SiriScreenBuilder.cloudSyncRow(enabled: false)
        XCTAssertEqual(off.detail, row.detail, "the (i) says what the sync does, on or off")
        XCTAssertTrue(off.steps.isEmpty)
    }

    /// Off with released models still on disk: MacSpace deletes them by itself (11 GB sat there after switching off, 2026-10-04).
    func testReleasedModelsOnDiskAreDeletedWithoutAsking() {
        var off = snapshot(.protected)
        off.installedModelBytes = 11_348_320_256
        off.recordedModelBytes = 11_348_320_256
        XCTAssertTrue(SiriModule.releasedModelsOnDisk(off))
        var on = snapshot(.atRisk)
        on.installedModelBytes = 11_348_320_256
        on.recordedModelBytes = 11_348_320_256
        XCTAssertFalse(SiriModule.releasedModelsOnDisk(on), "in use while Apple Intelligence is on")
        var elsewhere = snapshot(.protected, accounts: [other("tester")])
        elsewhere.installedModelBytes = 11_348_320_256
        elsewhere.recordedModelBytes = 11_348_320_256
        XCTAssertFalse(SiriModule.releasedModelsOnDisk(elsewhere), "another account keeps them locked")
        var empty = snapshot(.protected)
        empty.installedModelBytes = 0
        empty.recordedModelBytes = 0
        XCTAssertFalse(SiriModule.releasedModelsOnDisk(empty))
        XCTAssertTrue(SiriScreenBuilder.tile(off).graphic.map { "\($0)".contains("deleting") } ?? false)
        var kept = snapshot(.protected)
        kept.installedModelBytes = 367_300_000
        kept.recordedModelBytes = 367_300_000
        kept.lockedModelBytes = 367_300_000
        XCTAssertFalse(SiriModule.releasedModelsOnDisk(kept), "assets macOS still locks are not purged over and over")
        XCTAssertTrue(SiriScreenBuilder.tile(kept).graphic.map { "\($0)".contains("kept by macOS") } ?? false)
        // The folders can hold more than MobileAsset's records (19.89 GB against 11.35 GB, 2026-10-06): what a purge deletes is only
        // what the records hold.
        var untracked = snapshot(.protected)
        untracked.installedModelBytes = 19_890_000_000
        untracked.recordedModelBytes = 0
        XCTAssertFalse(SiriModule.releasedModelsOnDisk(untracked), "nothing a purge would delete")
    }

    func testModelsBeingDownloadedAreNeverNoModel() {
        var downloading = snapshot(.atRisk)
        downloading.installedModelBytes = 0
        downloading.downloadingModelBytes = 2_000_000_000
        XCTAssertFalse(SiriScreenBuilder.tile(downloading).graphic.map { "\($0)".contains("no model downloaded yet") } ?? true)
        var unreadable = snapshot(.atRisk)
        unreadable.installedModelBytes = nil
        XCTAssertTrue(SiriScreenBuilder.tile(unreadable).graphic.map { "\($0)".contains("models not measured") } ?? false)
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
        XCTAssertTrue(tile.status.hasPrefix("free up to"))
        guard case let .state(isOn, alarming, detail, _, _)? = tile.graphic else { return XCTFail() }
        XCTAssertTrue(isOn)
        XCTAssertFalse(alarming, "no glow")
        XCTAssertFalse(detail.contains("may download"))

        on.installedModelBytes = 0
        XCTAssertEqual(SiriScreenBuilder.tile(on).status, "AI is on")
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
        let ready = snapshot(.protected, purgeable: 12_000_000_000)
        let purge = try XCTUnwrap(SiriScreenBuilder.screen(ready).primary)
        XCTAssertEqual(purge.id, "purgeAssets")
        XCTAssertNotNil(purge.confirmation)
        XCTAssertNotEqual(SiriScreenBuilder.screen(snapshot(.protected, purgeable: 1_000)).primary?.id, "purgeAssets", "a few KB is not worth a button")
    }

    /// The Apple Intelligence row shows its models and where their cleanup stands as the feature rows do, with no section of its own.
    func testTheAppleIntelligenceRowShowsItsModelsLikeTheFeatureRows() {
        func row(_ snap: SiriSnapshot) -> ToggleRow { SiriScreenBuilder.switchList(snap).rows[0] }
        var on = snapshot(.atRisk)
        on.installedModelBytes = 9_000_000_000
        XCTAssertEqual(row(on).trailing, ByteFormat.string(9_000_000_000))
        XCTAssertNil(row(on).badge)
        on.downloadingModelBytes = 1_000_000_000
        XCTAssertEqual(row(on).trailing, ByteFormat.string(10_000_000_000), "downloads count as they arrive")
        XCTAssertEqual(row(on).badge?.text, "Downloading")

        var releasing = snapshot(.releasing)
        releasing.installedModelBytes = 9_000_000_000
        XCTAssertEqual(row(releasing).badge?.text, "macOS is freeing the model")
        releasing.releasingAutomatically = true
        XCTAssertEqual(row(releasing).badge?.role, .freeingInBackground)
        var blocked = snapshot(.releasing, blockers: ["Apple Intelligence is on in tester."])
        blocked.installedModelBytes = 9_000_000_000
        XCTAssertEqual(row(blocked).badge?.text, "Kept by macOS")
        XCTAssertEqual(row(blocked).badge?.help, "Apple Intelligence is on in tester.")
        var purging = snapshot(.protected)
        purging.installedModelBytes = 9_000_000_000
        purging.purgingModels = true
        XCTAssertEqual(row(purging).badge?.role, .freeingInBackground)

        let clean = snapshot(.protected)
        XCTAssertNil(row(clean).trailing)
        XCTAssertNil(row(clean).badge, "nothing worth a size is left: no pill")
        XCTAssertFalse(SiriScreenBuilder.screen(releasing).widgets.map(\.id).contains("models"), "no Leftover models section")
        XCTAssertEqual(row(purging).badge?.kind, .info, "a state is grey")
        XCTAssertEqual(row(blocked).badge?.kind, .action, "another account keeps them: something for the user to do")
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
        XCTAssertEqual(screen.widgets.map(\.id), ["status", "switch", "icloud", "accounts"])
    }
}

extension SiriScreenBuilderTests {
    /// While the models change, the tile asks to be read again every few seconds, so it follows a download without Refresh.
    func testTheTileAsksForQuickReadingsWhileTheModelsChange() {
        XCTAssertNil(SiriScreenBuilder.tile(snapshot(.atRisk)).refreshAfter, "AI being on alone does not require fast polling")
        var downloading = snapshot(.atRisk)
        downloading.downloadingModelBytes = 1_000_000
        XCTAssertEqual(SiriScreenBuilder.tile(downloading).refreshAfter, 5)
        XCTAssertEqual(SiriScreenBuilder.tile(snapshot(.releasing)).refreshAfter, 5)
        XCTAssertNil(SiriScreenBuilder.tile(snapshot(.protected)).refreshAfter, "settled: the usual minute")
        var retrying = snapshot(.protected)
        retrying.assetsRetrying = true
        XCTAssertNil(SiriScreenBuilder.tile(retrying).refreshAfter, "background requests are minutes apart: the usual minute")
    }
}

private final class SnapshotReads: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.withLock { count += 1; return count } }
    var total: Int { lock.withLock { count } }
    func waitForRelease(_ release: DispatchSemaphore) { _ = release.wait(timeout: .now() + 5) }
}

/// The restart notification is the module's words; the app posts it (`ModuleServices.notify`).
final class SiriRestartNoticeTests: XCTestCase {
    func testNoticeSaysWhatARestartFrees() {
        let big = SiriModule.restartNotice(SiriScreenBuilder.purgeThreshold)
        XCTAssertTrue(big.title.contains(ByteFormat.string(SiriScreenBuilder.purgeThreshold)))
        XCTAssertFalse(big.body.isEmpty)
        XCTAssertFalse(SiriModule.restartNotice(0).title.contains(ByteFormat.string(0)), "no figure under the threshold")
    }
}
