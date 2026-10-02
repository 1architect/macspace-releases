import XCTest
@testable import MacSpaceSystemData

final class AssetFamilyTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("assets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func asset(_ folder: String, _ specifier: String, mb: Int, nested: Bool = true) throws {
        let dir = root.appendingPathComponent(folder + (nested ? "/purpose_auto" : "")).appendingPathComponent("\(UUID().uuidString).asset")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("AssetData"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleName": "ignored", "MobileAssetProperties": ["AssetSpecifier": specifier]]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: dir.appendingPathComponent("Info.plist"))
        try Data(count: mb * 1_000_000).write(to: dir.appendingPathComponent("AssetData/blob"))
    }

    func testGroupsAssetsByTheSettingThatReleasesThem() throws {
        try asset("com_apple_MobileAsset_UAF_Siri_Understanding", "com.apple.siri.asr.assistant.pt_BR", mb: 30)
        try asset("com_apple_MobileAsset_UAF_Siri_Understanding", "com.apple.siri.asr.assistant.en_US", mb: 40)
        try asset("com_apple_MobileAsset_UAF_Siri_TextToSpeech", "com.apple.siri.tts.voice.en_US.simone.natural.premium", mb: 25)
        try asset("com_apple_MobileAsset_UAF_LinguisticData", "com.apple.linguisticdata.optional.fr-device", mb: 22)
        try asset("com_apple_MobileAsset_AppleDeveloperDocumentation", "DocumentationAsset", mb: 60, nested: false)
        try asset("com_apple_MobileAsset_Misc", "com.apple.something.else", mb: 21)
        try asset("com_apple_MobileAsset_Tiny", "com.apple.siri.tts.resource.en_US", mb: 1)

        let families = AssetFamilyScanner(root: root.path).scan()
        XCTAssertEqual(families.map(\.id), ["siri-speech", "developer-docs", "siri-voices", "language-data", "other"])
        let speech = try XCTUnwrap(families.first { $0.id == "siri-speech" })
        XCTAssertEqual(speech.assets, ["com.apple.siri.asr.assistant.en_US", "com.apple.siri.asr.assistant.pt_BR"])
        XCTAssertGreaterThanOrEqual(speech.bytes, 70_000_000)
        XCTAssertFalse(speech.steps.isEmpty)
        XCTAssertEqual(families.first { $0.id == "siri-voices" }?.assets.count, 2, "small assets count toward their family")
    }

    func testMissingFolderGivesNoFamilies() {
        XCTAssertEqual(AssetFamilyScanner(root: "/nonexistent-\(UUID().uuidString)").scan(), [])
    }

    func testScreenListsOnlyFamiliesWithASetting() throws {
        let family = AssetFamily(id: "siri-voices", title: "Siri voices", assets: ["a"], bytes: 300_000_000, heldBy: "Siri", steps: ["Do this"], verified: false)
        let none = AssetFamily(id: "photos-models", title: "Photos models", assets: ["b"], bytes: 800_000_000, heldBy: "Catalog", steps: [], verified: false)
        var snap = SystemDataSnapshot(
            report: SystemDataReport(schemaVersion: 1, generatedAt: Date(), volumes: [], items: [], measuredBytes: 0, cleanableBytes: 0, manualCleanup: [], unreadable: [], warnings: []),
            purgeableAssetsBytes: nil,
            reports: CleanupPlan(olderThanDays: 7, cutoff: .distantPast, candidates: [], totalBytes: 0, unreadableDirectories: []),
            takenAt: Date())
        snap.assetFamilies = [none, family]
        guard case let .section(section) = try XCTUnwrap(SystemDataScreenBuilder.assetsSection(snap)), case let .list(list) = section.widgets[0] else { return XCTFail() }
        XCTAssertEqual(list.rows.map(\.title), ["Siri voices"], "a download with no setting is nothing the user can act on")
        XCTAssertEqual(list.rows[0].steps, ["Do this"])
        XCTAssertNil(SystemDataScreenBuilder.assetsSection(SystemDataSnapshot(report: snap.report, purgeableAssetsBytes: nil, reports: snap.reports, takenAt: Date())))
    }
}
