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
    func testEveryOwnerScopeRequiresKnownUnavailableIntelligenceAndReviewedRuntime() {
        for scope in AssetModelCleanup.Scope.allCases {
            for available in [true,nil] as [Bool?] {
                XCTAssertNotNil(AssetModelCleanup.refusal(scope,available:available,supported:true,virtualMachine:false,settings:off,phone:phone))
            }
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
        for path in ["com_apple_MobileAsset_UAF_Photos_SpatialPhotosRelive/purpose_auto/test.asset", "com_apple_MobileAsset_Unrelated/other.asset"] {
            try FileManager.default.createDirectory(at:root.appendingPathComponent(path),withIntermediateDirectories:true)
        }
        XCTAssertEqual(AssetModelCleanup.inventory(.spatialPhotos,root:root.path),1)
        XCTAssertEqual(AssetModelCleanup.inventory(.phone,root:root.path),0)
        XCTAssertNil(AssetModelCleanup.inventory(.siri,root:root.appendingPathComponent("missing").path))
        for path in ["com_apple_MobileAsset_UAF_Speech_AutomaticSpeechRecognition/purpose_auto/asr.asset",
                     "com_apple_MobileAsset_UAF_Siri_TextToSpeech/purpose_auto/voice.asset"] {
            try FileManager.default.createDirectory(at:root.appendingPathComponent(path),withIntermediateDirectories:true)
        }
        XCTAssertEqual(AssetModelCleanup.inventory(.phone,root:root.path),2)
        XCTAssertEqual(AssetModelCleanup.inventory(.siri,root:root.path),1)
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
        empty.owners.error="Owner still active"
        XCTAssertFalse(AssetModelCleanup.needsReclaim([empty]))
    }
}
