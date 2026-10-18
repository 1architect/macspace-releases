import Foundation
import XCTest
import MacSpacePlatform

final class FeatureFlagOverridesTests: XCTestCase {
    private func temporaryFile() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder.appendingPathComponent("TelephonyUtilities.plist")
    }

    func testRestorePreservesOriginalPhaseAndUnrelatedChangesMadeAfterDisabling() throws {
        let url = try temporaryFile()
        let before: [String: Any] = ["AudioCallTranslationMac": ["DevelopmentPhase": "FeatureComplete", "Owner": "original"],
                                    "Unrelated": ["Enabled": true]]
        try PropertyListSerialization.data(fromPropertyList: before, format: .binary, options: 0).write(to: url)
        let entry = try FeatureFlagOverrides.entry(feature: "AudioCallTranslationMac", path: url.path)
        try FeatureFlagOverrides.update(feature: "AudioCallTranslationMac", enabled: false, path: url.path)
        var root = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        let disabled = try XCTUnwrap(root["AudioCallTranslationMac"] as? [String: Any])
        XCTAssertEqual(disabled["Enabled"] as? Bool, false)
        XCTAssertNil(disabled["DevelopmentPhase"])
        // Another control or administrator changes its own entry while Phone is off.
        try FeatureFlagOverrides.update(feature: "Unrelated", enabled: false, path: url.path)
        try FeatureFlagOverrides.restore(feature: "AudioCallTranslationMac", entry: entry, path: url.path)
        root = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        XCTAssertEqual(root["AudioCallTranslationMac"] as? NSDictionary, before["AudioCallTranslationMac"] as? NSDictionary)
        XCTAssertEqual((root["Unrelated"] as? [String: Any])?["Enabled"] as? Bool, false)
    }

    func testAnAbsentEntryAndFileReturnToAbsence() throws {
        let url = try temporaryFile()
        let before = try FeatureFlagOverrides.entry(feature: "AudioCallTranslationMac", path: url.path)
        XCTAssertNil(before)
        try FeatureFlagOverrides.update(feature: "AudioCallTranslationMac", enabled: false, path: url.path)
        try FeatureFlagOverrides.restore(feature: "AudioCallTranslationMac", entry: before, path: url.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testUnreadableOrCorruptExistingDomainIsNeverReplaced() throws {
        let url = try temporaryFile()
        let data = Data("not a property list".utf8)
        try data.write(to: url)
        XCTAssertThrowsError(try FeatureFlagOverrides.entry(feature: "CallRecording", path: url.path))
        XCTAssertThrowsError(try FeatureFlagOverrides.update(feature: "CallRecording", enabled: false, path: url.path))
        XCTAssertThrowsError(try FeatureFlagOverrides.restore(feature: "CallRecording", entry: nil, path: url.path))
        XCTAssertEqual(try Data(contentsOf: url), data)
    }
}
