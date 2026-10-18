import Foundation
import XCTest
@testable import MacSpacePlatform

final class PhoneFeatureFlagsTests: XCTestCase {
    final class Values: @unchecked Sendable {
        var flags = Dictionary(uniqueKeysWithValues: PhoneFeatureFlags.features.map { ($0, true) })
        var boot = "first"
    }

    func fixture(supported: Bool = true) throws -> (PhoneFeatureFlags, Values, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let values = Values()
        let control = PhoneFeatureFlags(overrideURL: directory.appendingPathComponent("flags.plist"),
                                       journalURL: directory.appendingPathComponent("journal.json"),
                                       supported: supported, effective: { values.flags[$0] }, bootSession: { values.boot })
        return (control, values, directory)
    }

    func plist(_ object: Any) throws -> Data { try PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0) }

    func testSavingOverridesDoesNotReportOffUntilEveryEffectiveGateIsOff() throws {
        let (control, values, _) = try fixture()
        XCTAssertEqual(control.status().state, .on)
        let pending = try control.setOff(true)
        XCTAssertEqual(pending.state, .restartRequired)
        XCTAssertFalse(pending.managedOff)
        for feature in PhoneFeatureFlags.features { values.flags[feature] = false }
        values.flags["VideoCallTranslationMac"] = true
        XCTAssertEqual(control.status().state, .restartRequired)
        XCTAssertFalse(control.status().managedOff)
        values.flags["VideoCallTranslationMac"] = false
        values.boot = "second"
        XCTAssertEqual(control.status().state, .off)
        XCTAssertTrue(control.status().managedOff)
    }

    func testRestoreKeepsMetadataAndUnrelatedEditsAndWaitsForEffectiveOriginalValues() throws {
        let (control, values, _) = try fixture()
        let original: [String: Any] = ["AudioCallTranslationMac": ["DevelopmentPhase": "FeatureComplete", "Marker": "original"],
                                       "Unrelated": ["Enabled": true]]
        try plist(original).write(to: control.overrideURL)
        _ = try control.setOff(true)
        values.flags = values.flags.mapValues { _ in false }
        values.boot = "second"
        try FeatureFlagOverrides.update(feature: "Unrelated", enabled: false, path: control.overrideURL.path)
        XCTAssertEqual(try control.setOff(false).state, .restartRequired)
        XCTAssertFalse(control.status().managedOff)
        let restored = try PhoneFeatureFlags.dictionary(Data(contentsOf: control.overrideURL))
        XCTAssertEqual(restored["AudioCallTranslationMac"] as? NSDictionary, original["AudioCallTranslationMac"] as? NSDictionary)
        XCTAssertEqual((restored["Unrelated"] as? [String: Any])?["Enabled"] as? Bool, false)
        XCTAssertEqual(restored.count, 2)
        values.flags = values.flags.mapValues { _ in true }; values.boot = "third"
        XCTAssertEqual(control.status().state, .on)
    }

    func testExternalDriftRefusesTheWholeOperationBeforeChangingOtherEntries() throws {
        let (control, _, _) = try fixture()
        _ = try control.setOff(true)
        try FeatureFlagOverrides.update(feature: "CallRecording", enabled: true, path: control.overrideURL.path)
        let before = try Data(contentsOf: control.overrideURL)
        XCTAssertEqual(control.status().state, .changedElsewhere)
        XCTAssertFalse(control.status().managedOff)
        XCTAssertThrowsError(try control.setOff(false))
        XCTAssertEqual(try Data(contentsOf: control.overrideURL), before)
    }

    func testUnknownOrUnsupportedGateNeverStartsAnOffOperation() throws {
        let (control, values, _) = try fixture()
        values.flags.removeValue(forKey: "CallRecording")
        XCTAssertEqual(control.status().state, .unknown)
        XCTAssertThrowsError(try control.setOff(true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: control.overrideURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: control.journalURL.path))
        let (unsupported, _, _) = try fixture(supported: false)
        XCTAssertEqual(unsupported.status().state, .unsupported)
        XCTAssertThrowsError(try unsupported.setOff(true))
    }

    func testResearchTrialRestoresItsActualOriginalsInsteadOfCapturingTheTrialsFalseBaseline() throws {
        let (base, values, directory) = try fixture()
        let trial = directory.appendingPathComponent("trial.plist")
        let written = Dictionary(uniqueKeysWithValues: PhoneFeatureFlags.features.map { ($0, ["Enabled": false]) })
        let original = ["AudioCallTranslationMac": ["DevelopmentPhase": "FeatureComplete"]]
        try plist(["version": 1, "build": "26B5112a", "before": original, "written": written]).write(to: trial)
        try plist(written).write(to: base.overrideURL)
        values.flags = values.flags.mapValues { _ in false }
        let control = PhoneFeatureFlags(overrideURL: base.overrideURL, journalURL: base.journalURL, trialURL: trial,
                                       effective: { values.flags[$0] }, bootSession: { values.boot })
        XCTAssertFalse(control.status().managedOff, "A trial is not a standing production cleanup intent")
        _ = try control.setOff(true)
        XCTAssertTrue(control.status().managedOff)
        XCTAssertEqual(try control.setOff(false).state, .restartRequired)
        XCTAssertEqual(try PhoneFeatureFlags.dictionary(Data(contentsOf: control.overrideURL)) as NSDictionary, original as NSDictionary)
        values.flags = values.flags.mapValues { _ in true }; values.boot = "second"
        XCTAssertEqual(control.status().state, .on)
    }

    func testInterruptedWriteCanResumeAndUnreviewedReleaseStillAllowsRestoration() throws {
        let (control, values, _) = try fixture()
        _ = try control.setOff(true)
        let journal = try XCTUnwrap(control.load())
        try FeatureFlagOverrides.restore(feature: journal.entries[0].feature, entry: journal.entries[0].before, path: control.overrideURL.path)
        _ = try control.setOff(true)
        values.flags = values.flags.mapValues { _ in false }
        XCTAssertTrue(control.status().managedOff)
        let future = PhoneFeatureFlags(overrideURL: control.overrideURL, journalURL: control.journalURL, supported: false,
                                      effective: { values.flags[$0] }, declared: { _ in false }, bootSession: { values.boot })
        XCTAssertNoThrow(try future.setOff(false), "An OS update must never strand an override MacSpace owns")
        XCTAssertFalse(FileManager.default.fileExists(atPath: control.overrideURL.path))
    }

    func testCorruptJournalCannotBecomeANewBaseline() throws {
        let (control, _, _) = try fixture()
        _ = try control.setOff(true)
        let before = try Data(contentsOf: control.overrideURL)
        try Data("invalid".utf8).write(to: control.journalURL)
        XCTAssertEqual(control.status().state, .unknown)
        XCTAssertThrowsError(try control.setOff(true))
        XCTAssertEqual(try Data(contentsOf: control.overrideURL), before)
    }

    func testAnOriginallyDisabledFeatureDoesNotGetStuckWaitingForRestartOnRestore() throws {
        let (control, values, _) = try fixture()
        values.flags = values.flags.mapValues { _ in false }
        _ = try control.setOff(true)
        let restored = try control.setOff(false)
        XCTAssertEqual(restored.state, .off)
        XCTAssertFalse(restored.managedOff)
        XCTAssertFalse(FileManager.default.fileExists(atPath: control.overrideURL.path))
    }

    func testRestorationRelinquishesOwnershipAndTheNextOffActionCapturesExternalChanges() throws {
        let (control, values, _) = try fixture()
        _ = try control.setOff(true)
        _ = try control.setOff(false)
        XCTAssertFalse(control.hasSavedSettings)
        values.boot = "second"
        try FeatureFlagOverrides.update(feature: "CallRecording", enabled: false, path: control.overrideURL.path)
        let external = try Data(contentsOf: control.overrideURL)
        _ = try control.setOff(false)
        XCTAssertEqual(try Data(contentsOf: control.overrideURL), external, "Repeated enable/uninstall must not restore old data over a new external setting")
        _ = try control.setOff(true)
        _ = try control.setOff(false)
        XCTAssertEqual(try PhoneFeatureFlags.dictionary(Data(contentsOf: control.overrideURL)) as NSDictionary,
                       try PhoneFeatureFlags.dictionary(external) as NSDictionary)
    }

    func testOnThenOffBeforeRestartKeepsTheOriginalRuntimeBaseline() throws {
        let (control, values, _) = try fixture()
        _ = try control.setOff(true)
        values.flags = values.flags.mapValues { _ in false }; values.boot = "second"
        _ = try control.setOff(false)
        _ = try control.setOff(true)
        XCTAssertEqual(try control.setOff(false).state, .restartRequired)
        values.flags = values.flags.mapValues { _ in true }; values.boot = "third"
        XCTAssertEqual(control.status().state, .on)
    }
}
