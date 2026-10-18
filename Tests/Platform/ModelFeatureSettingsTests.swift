import Foundation
import XCTest
@testable import MacSpacePlatform

final class ModelFeatureSettingsTests: XCTestCase {
    final class Preferences: @unchecked Sendable {
        var values: [String: Data] = [:]
        var failKey: String?
        var writes = 0
        func read(_ domain: String, _ key: String) -> Data? { values[domain + "/" + key] }
        func write(_ domain: String, _ key: String, _ value: Data?) throws {
            if key == failKey { throw CocoaError(.fileWriteUnknown) }
            writes += 1; values[domain + "/" + key] = value
        }
    }
    func fixture(supported: Bool = true) throws -> (ModelFeatureSettings, Preferences) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let preferences = Preferences()
        return (ModelFeatureSettings(directory: directory, supported: supported, read: preferences.read, write: preferences.write), preferences)
    }
    func testSiriRestoresCompleteVoiceAndPreservesLanguage() throws {
        let (settings, prefs) = try fixture()
        let language = "com.apple.assistant.backedup/Session Language"
        let voice = "com.apple.assistant.backedup/Output Voice"
        prefs.values[language] = try ModelFeatureSettings.pack("en-US")
        let original = try ModelFeatureSettings.pack(["language": "pt-BR", "name": "Sandra", "quality": "premium"])
        prefs.values[voice] = original
        prefs.values["com.apple.assistant.support/Assistant Enabled"] = try ModelFeatureSettings.pack(true)
        try settings.setOff(true, feature: .siri)
        XCTAssertTrue(settings.status(.siri).managedOff)
        XCTAssertNil(prefs.values[voice])
        XCTAssertEqual(try ModelFeatureSettings.unpack(XCTUnwrap(prefs.values[language])) as? String, "en-US")
        try settings.setOff(false, feature: .siri)
        XCTAssertTrue(try ModelFeatureSettings.equal(prefs.values[voice], original))
        XCTAssertEqual(settings.status(.siri).state, .on)
        XCTAssertFalse(settings.hasSavedSettings(.siri))
    }
    func testSpatialPhotoAbsenceAndUnrelatedPreferencesAreRestoredExactly() throws {
        let (settings, prefs) = try fixture()
        prefs.values["com.apple.spatialphotosrelive/Other"] = try ModelFeatureSettings.pack("keep")
        XCTAssertEqual(settings.status(.spatialPhotos).state, .on)
        try settings.setOff(true, feature: .spatialPhotos)
        try settings.setOff(true, feature: .spatialPhotos)
        try settings.setOff(false, feature: .spatialPhotos)
        XCTAssertNil(prefs.values["com.apple.spatialphotosrelive/LocallyDisabled"])
        XCTAssertNotNil(prefs.values["com.apple.spatialphotosrelive/Other"])
    }
    func testPhoneCaptionsAndRecordingRestoreTheirIndividualOriginals() throws {
        let (settings, prefs) = try fixture()
        let captions = "com.apple.Accessibility/FaceTimeCaptions"
        prefs.values[captions] = try ModelFeatureSettings.pack(true)
        try settings.setOff(true, feature: .phone)
        XCTAssertTrue(settings.status(.phone).managedOff)
        try settings.setOff(false, feature: .phone)
        XCTAssertEqual(try ModelFeatureSettings.unpack(XCTUnwrap(prefs.values[captions])) as? Bool, true)
        XCTAssertNil(prefs.values["com.apple.TelephonyUtilities/CallRecordingDisabled"])
        XCTAssertNil(prefs.values["com.apple.Accessibility/LiveTranscriptionInCallEnabled"])
    }
    func testExternalVoiceChangeStopsAutomaticOwnershipAndRestoreBeforeAnyWrite() throws {
        let (settings, prefs) = try fixture()
        prefs.values["com.apple.assistant.support/Assistant Enabled"] = try ModelFeatureSettings.pack(true)
        try settings.setOff(true, feature: .siri)
        prefs.values["com.apple.assistant.backedup/Output Voice"] = try ModelFeatureSettings.pack(["name": "new choice"])
        let writes = prefs.writes
        XCTAssertEqual(settings.status(.siri).state, .changedElsewhere)
        XCTAssertFalse(settings.status(.siri).managedOff)
        XCTAssertThrowsError(try settings.setOff(false, feature: .siri))
        XCTAssertEqual(prefs.writes, writes)
    }
    func testPartialRestoreKeepsRollbackStateAndCanResume() throws {
        let (settings, prefs) = try fixture()
        prefs.values["com.apple.assistant.support/Assistant Enabled"] = try ModelFeatureSettings.pack(true)
        prefs.values["com.apple.assistant.backedup/Output Voice"] = try ModelFeatureSettings.pack(["name": "original"])
        try settings.setOff(true, feature: .siri)
        prefs.failKey = "Output Voice"
        XCTAssertThrowsError(try settings.setOff(false, feature: .siri))
        XCTAssertTrue(settings.hasSavedSettings(.siri))
        XCTAssertFalse(settings.status(.siri).managedOff)
        prefs.failKey = nil
        try settings.setOff(false, feature: .siri)
        XCTAssertFalse(settings.hasSavedSettings(.siri))
        XCTAssertNotNil(prefs.values["com.apple.assistant.backedup/Output Voice"])
    }
    func testUnreviewedBuildRefusesNewDisableButPermitsSavedRestore() throws {
        let (settings, prefs) = try fixture()
        try settings.setOff(true, feature: .spatialPhotos)
        let unreviewed = ModelFeatureSettings(directory: settings.directory, supported: false, read: prefs.read, write: prefs.write)
        XCTAssertThrowsError(try unreviewed.setOff(true, feature: .phone))
        try unreviewed.setOff(false, feature: .spatialPhotos)
        XCTAssertNil(prefs.values["com.apple.spatialphotosrelive/LocallyDisabled"])
    }
    func testExternallyDisabledFeatureDoesNotAuthorizeAutomaticCleanup() throws {
        let (settings, prefs) = try fixture()
        prefs.values["com.apple.spatialphotosrelive/LocallyDisabled"] = try ModelFeatureSettings.pack(true)
        XCTAssertEqual(settings.status(.spatialPhotos).state, .off)
        XCTAssertFalse(settings.status(.spatialPhotos).managedOff)
    }
}
