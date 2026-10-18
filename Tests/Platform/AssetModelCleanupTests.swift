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
    }
    func testCommandRejectsArbitraryScopeAndModeBeforeAnyNativeCall() throws {
        for (scope,mode) in [("/tmp","release"),("siri","delete"),("spatialPhotos","release")] {
            let result=try JSONDecoder().decode(AssetModelCleanup.OwnerResult.self,from:AssetModelCleanup.runInChild(scope:scope,mode:mode))
            XCTAssertNotNil(result.error)
            XCTAssertEqual(result.releasedOwners,0)
        }
    }
}
