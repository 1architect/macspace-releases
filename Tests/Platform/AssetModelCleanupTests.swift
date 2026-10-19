import Foundation
import XCTest
@testable import MacSpacePlatform

final class AssetModelCleanupTests: XCTestCase {
    var off: [ModelFeatureSettings.Feature: ModelFeatureSettings.Status] {
        Dictionary(uniqueKeysWithValues: ModelFeatureSettings.Feature.allCases.map { ($0,.init(state:.off,managedOff:true,requestedOff:true)) })
    }
    var phone: PhoneFeatureFlags.Status {
        .init(state:.off,managedOff:true,effective:Dictionary(uniqueKeysWithValues:PhoneFeatureFlags.features.map{($0,false)}),requestedOff:true)
    }
    func testCatalogRecordsLeftWithNoOwnerAreNotModels() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("assets-\(UUID().uuidString)")
        let family = root.appendingPathComponent("com_apple_MobileAsset_UAF_Siri_Understanding/purpose_auto")
        try FileManager.default.createDirectory(at: family.appendingPathComponent("metadata.asset"), withIntermediateDirectories: true)
        try Data(count: 8_000).write(to: family.appendingPathComponent("metadata.asset/AssetData"))
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(AssetModelCleanup.inventory(.siri, withdrew: false, root: root.path), 0, "an 8 KB catalog record is not a model")
        try FileManager.default.createDirectory(at: family.appendingPathComponent("model.asset"), withIntermediateDirectories: true)
        try Data(count: 2_000_000).write(to: family.appendingPathComponent("model.asset/AssetData"))
        XCTAssertEqual(AssetModelCleanup.inventory(.siri, withdrew: false, root: root.path), 1)
    }

    func testLockedAssetsCountOnlyTheFeaturesOwnFamilies() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("locks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["AutoAssetLocker_Entry_com.apple.MobileAsset.UAF.Siri.Understanding_com.apple.siri.asr.assistant.en_US_1_0.state",
                     "AutoAssetLocker_Entry_com.apple.MobileAsset.UAF.Siri.UnderstandingNLOverrides_com.apple.siri.nl.overrides.pt_BR_1_0.state",
                     "AutoAssetLocker_Entry_com.apple.MobileAsset.UAF.Photos.SpatialPhotosRelive_main_1_0.state"] {
            FileManager.default.createFile(atPath: folder.appendingPathComponent(name).path, contents: Data())
        }
        XCTAssertEqual(AssetModelCleanup.lockedAssets(.siri, lockDirectory: folder.path), 1, "the overrides family is not Siri's models")
        XCTAssertEqual(AssetModelCleanup.lockedAssets(.spatialPhotos, lockDirectory: folder.path), 1)
        XCTAssertEqual(AssetModelCleanup.lockedAssets(.phone, lockDirectory: folder.path), 0)
    }

    func testSiriLanguageAliasesQualifyByWhatMacOSDefinesThemToRequest() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("aliases-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func write(_ name: String, _ usages: [String]) throws {
            let values = ["pt-BR": Dictionary(uniqueKeysWithValues: usages.map { ($0, [String: String]()) })]
            try PropertyListSerialization.data(fromPropertyList: ["UsageAliasName": name, "UsageAliasValues": values], format: .xml, options: 0)
                .write(to: folder.appendingPathComponent(name + ".plist"))
        }
        try write("com.apple.siri.assistant.assistantengine.language", ["com.apple.if.planner", "com.apple.siri.understanding"])
        try write("com.apple.siri.assistant.dialog.language", ["com.apple.siri.dialog"])
        XCTAssertTrue(AssetOwners.isSiriLanguageAlias("com.apple.siri.assistant.assistantengine.language", folder: folder.path))
        XCTAssertFalse(AssetOwners.isSiriLanguageAlias("com.apple.siri.assistant.dialog.language", folder: folder.path), "no understanding models")
        XCTAssertFalse(AssetOwners.isSiriLanguageAlias("com.apple.siri.assistant.missing.language", folder: folder.path), "not defined by macOS")
        XCTAssertFalse(AssetOwners.isSiriLanguageAlias("com.apple.siri.nl.system.language", folder: folder.path))
    }

    func testFeatureScopesRunWithIntelligenceOnOrOffAndLanguageDataOnlyWhileOff() {
        for scope in AssetModelCleanup.Scope.allCases {
            XCTAssertNotNil(AssetModelCleanup.refusal(scope,available:nil,supported:true,virtualMachine:false,settings:off,phone:phone),
                            "unknown eligibility never authorizes owner mutation")
            let on = AssetModelCleanup.refusal(scope,available:true,supported:true,virtualMachine:false,settings:off,phone:phone)
            if scope == .released { XCTAssertNotNil(on, "Apple Intelligence reads the language data") } else { XCTAssertNil(on) }
            XCTAssertNotNil(AssetModelCleanup.refusal(scope,available:false,supported:false,virtualMachine:false,settings:off,phone:phone))
            XCTAssertNotNil(AssetModelCleanup.refusal(scope,available:false,supported:true,virtualMachine:true,settings:off,phone:phone))
            XCTAssertNil(AssetModelCleanup.refusal(scope,available:false,supported:true,virtualMachine:false,settings:off,phone:phone))
        }
    }
    func testPhoneSavedIntentAndNativePrefsCannotReplaceVerifiedPostRestartGates() {
        var pending=phone
        pending.state = .restartRequired;pending.managedOff=false
        XCTAssertNotNil(AssetModelCleanup.refusal(.phone,available:false,supported:true,virtualMachine:false,settings:off,phone:pending))
        var native=off
        native[.phone] = .init(state:.changedElsewhere)
        XCTAssertNotNil(AssetModelCleanup.refusal(.phone,available:false,supported:true,virtualMachine:false,settings:native,phone:phone))
    }
    func testExternallyDisabledControlsNeverAuthorizeRecurringOwnerWithdrawal() {
        for feature in ModelFeatureSettings.Feature.allCases {
            var settings=off
            settings[feature] = .init(state:.off,managedOff:false)
            let scope=AssetModelCleanup.Scope(rawValue:feature.rawValue)!
            XCTAssertNotNil(AssetModelCleanup.refusal(scope,available:false,supported:true,virtualMachine:false,settings:settings,phone:phone))
        }
    }
    func testSpatialPhotoControlIsIndependentOfSiriAndPhoneControls() {
        let settings: [ModelFeatureSettings.Feature:ModelFeatureSettings.Status] = [.spatialPhotos:.init(state:.off,managedOff:true)]
        XCTAssertNil(AssetModelCleanup.refusal(.spatialPhotos,available:false,supported:true,virtualMachine:false,settings:settings,phone:.init(state:.on,managedOff:false,effective:[:])))
    }
    func testTargetInventoryExcludesUnrelatedFamiliesAndKeepsUnknownSeparateFromEmpty() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock {try? FileManager.default.removeItem(at:root)}
        // A model's worth of data: smaller assets are catalog records (`AssetModelCleanup.modelAssetBytes`).
        func model(_ path: String) throws {
            try FileManager.default.createDirectory(at:root.appendingPathComponent(path),withIntermediateDirectories:true)
            try Data(count: 2_000_000).write(to: root.appendingPathComponent(path + "/AssetData"))
        }
        for path in ["com_apple_MobileAsset_UAF_Photos_SpatialPhotosRelive/purpose_auto/test.asset", "com_apple_MobileAsset_Unrelated/other.asset"] {
            try model(path)
        }
        XCTAssertEqual(AssetModelCleanup.inventory(.spatialPhotos,root:root.path),1)
        XCTAssertEqual(AssetModelCleanup.inventory(.phone,root:root.path),0)
        XCTAssertNil(AssetModelCleanup.inventory(.siri,root:root.appendingPathComponent("missing").path))
        for path in ["com_apple_MobileAsset_UAF_Speech_AutomaticSpeechRecognition/purpose_auto/asr.asset",
                     "com_apple_MobileAsset_UAF_Siri_TextToSpeech/purpose_auto/voice.asset"] {
            try model(path)
        }
        XCTAssertEqual(AssetModelCleanup.inventory(.phone,root:root.path),2)
        XCTAssertEqual(AssetModelCleanup.inventory(.siri,root:root.path),1)
        XCTAssertEqual(AssetModelCleanup.inventory(.phone,withdrew:false,root:root.path),0,"other features' models in shared families do not keep Phone cleaning")
        XCTAssertEqual(AssetModelCleanup.inventory(.siri,withdrew:false,root:root.path),0,"Siri's voices are shared too")
        try model("com_apple_MobileAsset_UAF_Siri_Understanding/u.asset")
        XCTAssertEqual(AssetModelCleanup.inventory(.siri,withdrew:false,root:root.path),1)
    }
    func testCommandRejectsArbitraryScopeAndModeBeforeAnyNativeCall() throws {
        for (scope,mode) in [("/tmp","release"),("siri","delete"),("spatialPhotos","release")] {
            let result=try JSONDecoder().decode(AssetModelCleanup.OwnerResult.self,from:AssetModelCleanup.runInChild(scope:scope,mode:mode))
            XCTAssertNotNil(result.error)
            XCTAssertEqual(result.releasedOwners,0)
        }
    }

    func testUnknownEligibilityAnswersDoNotBecomePermissionForOwnerCleanup() throws {
        for answer in [0,1,2,3,4,5] {
            let data = try PropertyListSerialization.data(fromPropertyList: ["OS_ELIGIBILITY_DOMAIN_SIRI_MODE": ["os_eligibility_answer_t":answer]], format:.binary,options:0)
            XCTAssertEqual(SystemAssetGuard.reviewedAvailability(inEligibility:data),answer == 2 ? false : answer == 4 ? true : nil)
        }
    }

    func testFeaturePolicyRefusesPurgeBeforeAnyEstimateOrMutation() {
        let retrier = PurgeRetrier()
        let result = PurgeRun(service: CacheDeleteService.mobileAsset, retrier: retrier, extraRefusal: { "Feature was enabled" }).run()
        XCTAssertTrue(result.skipped)
        XCTAssertTrue(result.held)
        XCTAssertNil(result.estimate)
        XCTAssertEqual(result.error,"Feature was enabled")
        XCTAssertFalse(retrier.isRetrying(CacheDeleteService.mobileAsset))
    }

    func testEmptyTargetInventoryDoesNotStartAnotherPurgeButUnknownIsRechecked() {
        var empty = AssetModelCleanup.Result(scope:.siri,owners:.init(releasedOwners:2))
        empty.remainingAssets=0
        XCTAssertFalse(AssetModelCleanup.needsReclaim([empty]),"removing metadata alone does not justify purging unrelated files")
        empty.remainingAssets=nil
        XCTAssertTrue(AssetModelCleanup.needsReclaim([empty]),"unreadable targets are not empty")
        empty.remainingAssets=0
        empty.owners.releasedOwners=0
        XCTAssertFalse(AssetModelCleanup.needsReclaim([empty]),"a recheck that withdrew nothing does not purge or retry")
        empty.owners.releasedOwners=1
        empty.owners.error="Owner still active"
        XCTAssertFalse(AssetModelCleanup.needsReclaim([empty]))
    }

    /// Journals saved by the earlier Objective-C bridge (NSNumber values, absent optional keys) must keep their rollback records.
    func testJournalsFromTheEarlierBridgeStillLoad() throws {
        let saved: [String: Any] = ["version": 1, "scope": "phone", "uid": NSNumber(value: getuid()), "cycleRemoved": 2, "entries": [
            ["kind": "uaf", "client": "com.apple.TelephonyUtilities", "name": "transcription.pt", "archive": Data([1]), "phase": "removed",
             "user": "2A106008-EC1C-41AD-B02F-950839090C0A", "expiry": NSNumber(value: 0.0)],
            ["kind": "tts", "client": "com.apple.TelephonyUtilities", "name": "voices", "archive": Data([2]), "phase": "submitted"]]]
        let data = try PropertyListSerialization.data(fromPropertyList: saved, format: .binary, options: 0)
        let entries = try AssetOwners.Journal.entries(data, scope: .phone)
        XCTAssertEqual(entries.map(\.phase), [.removed, .submitted])
        XCTAssertEqual(entries[0].expiry, 0)
        XCTAssertNil(entries[1].user)
        XCTAssertThrowsError(try AssetOwners.Journal.entries(data, scope: .siri), "a journal is never read for another scope")
    }

    /// A private object without the reviewed property refuses instead of raising inside the child.
    func testUnreviewedOwnerPropertyRefuses() throws {
        XCTAssertThrowsError(try AssetOwners.value(NSObject(), "assetSets"))
        XCTAssertNil(try AssetOwners.value(nil, "name"))
        XCTAssertEqual(try AssetOwners.value(["name": "a"] as NSDictionary, "name") as? String, "a")
        XCTAssertTrue(AssetOwners.equal(NSNumber(value: 1), NSNumber(value: true)), "TelephonyUtilities can store a Boolean as 1")
        XCTAssertFalse(AssetOwners.equal(nil, NSNumber(value: false)))
    }
}
