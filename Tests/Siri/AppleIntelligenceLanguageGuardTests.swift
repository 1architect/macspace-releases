import XCTest
@testable import MacSpaceSiri
import MacSpacePlatform
import MacSpaceSiriPrivileged

/// Siri languages returned by AFPreferencesSupportedLanguages on 26B5091g (CP112).
private let siriLanguages = ["en-US", "de-DE", "de-CH", "en-AU", "en-GB", "en-CA", "en-SG", "es-ES", "es-MX", "es-US", "fr-FR",
                             "fr-CA", "fr-CH", "it-IT", "it-CH", "ja-JP", "ko-KR", "zh-CN", "zh-TW", "zh-HK", "pt-BR", "da-DK",
                             "nl-NL", "en-NZ", "en-IN", "ru-RU", "sv-SE", "th-TH", "tr-TR", "nb-NO", "de-AT", "fr-BE", "nl-BE",
                             "ar-SA", "fi-FI", "he-IL", "ms-MY", "es-CL", "en-ZA", "yue-CN", "en-IE", "vi-VN", "pt-PT"]

private final class FakeSiriEnvironment: SiriLanguageEnvironment {
    var ctx: SiriLanguageContext
    var voice: Data?
    var saved: SavedSiriSettings?
    /// Eligibility as a function of the current Siri language; nil models an unreadable eligibility file.
    var eligibility: (String?) -> Int?
    var writes: [String] = []

    init(system: String, siri: String, installed: [String] = [], voice: Data? = Data([1]),
         eligibility: @escaping (String?) -> Int?) {
        ctx = SiriLanguageContext(systemLanguage: system, siriLanguage: siri, siriEnabled: false,
                                  supportedSiriLanguages: siriLanguages, installedSiriLanguages: installed)
        self.voice = voice
        self.eligibility = eligibility
    }

    func context() -> SiriLanguageContext { ctx }
    func outputVoice() -> Data? { voice }
    func eligibilityAnswer() -> Int? { eligibility(ctx.siriLanguage) }
    func write(siriLanguage: String, outputVoice: Data?) throws {
        writes.append(siriLanguage)
        ctx.siriLanguage = siriLanguage
        if let outputVoice { voice = outputVoice }
    }
    func loadSavedSettings() -> SavedSiriSettings? { saved }
    func saveSettings(_ settings: SavedSiriSettings?) throws { saved = settings }
    func sleep(seconds: Double) {}
}

/// The CP111/CP112 rule: eligible only while the Siri base language equals the system base language.
private func mismatchRule(system: String) -> (String?) -> Int? {
    { siri in siri.map { AppleIntelligenceLanguageGuard.baseLanguage($0) == AppleIntelligenceLanguageGuard.baseLanguage(system) ? 4 : 2 } }
}

final class AppleIntelligenceLanguageGuardTests: XCTestCase {
    private let guardian = AppleIntelligenceLanguageGuard()

    private func autoSet(selectors: Int, targets: Int, error: String? = nil) -> AutoSetConfigurationObservation {
        AutoSetConfigurationObservation(sourcePath: "fixture.state", sha256: "abc", byteCount: 1, selectorCount: selectors,
                                        targetCount: targets, targetSelectors: Array(repeating: AppleIntelligenceLanguageGuard.targetSpecifier, count: targets),
                                        error: error)
    }

    private func inputs(system: String? = "pt-BR", siri: String? = "en-US", answer: Int? = 2,
                        selectors: Int = 2, targets: Int = 0, installed: [String]? = []) -> AppleIntelligenceGuardInputs {
        AppleIntelligenceGuardInputs(systemLanguage: system, siriLanguage: siri, siriModeAnswer: answer,
                                     autoSetConfiguration: autoSet(selectors: selectors, targets: targets),
                                     installedTargetAssets: installed)
    }

    private func context(system: String, siri: String, installed: [String] = [], siriEnabled: Bool = false) -> SiriLanguageContext {
        SiriLanguageContext(systemLanguage: system, siriLanguage: siri, siriEnabled: siriEnabled,
                            supportedSiriLanguages: siriLanguages, installedSiriLanguages: installed)
    }

    // MARK: Status: eligibility is authoritative

    func testBaseLanguageComparesLanguageNotRegion() {
        XCTAssertEqual(AppleIntelligenceLanguageGuard.baseLanguage("pt-BR"), "pt")
        XCTAssertEqual(AppleIntelligenceLanguageGuard.baseLanguage("pt_PT"), "pt")
        XCTAssertEqual(AppleIntelligenceLanguageGuard.baseLanguage("yue-CN"), "yue")
    }

    func testCP111PostbootStateIsProtectedByLanguageMismatch() {
        let status = guardian.evaluate(inputs())
        XCTAssertEqual(status.state, .protected)
        XCTAssertEqual(status.ineligibilitySource, .languageMismatch)
    }

    func testIneligibleWithModelStillPresentIsReleasing() {
        XCTAssertEqual(guardian.evaluate(inputs(targets: 1, installed: ["a6e4.asset"])).state, .releasing)
        XCTAssertEqual(guardian.evaluate(inputs(targets: 0, installed: ["a6e4.asset"])).state, .releasing)
    }

    func testEligibleIsAtRiskEvenWhenLanguagesDiffer() {
        XCTAssertEqual(guardian.evaluate(inputs(siri: "pt-BR", answer: 4, selectors: 177, targets: 1)).state, .atRisk)
        let differing = guardian.evaluate(inputs(answer: 4))
        XCTAssertEqual(differing.state, .atRisk)
        XCTAssertTrue(differing.reasons.contains { $0.contains("may not apply on this build") })
    }

    func testMatchingLanguagesButIneligibleIsProtectedForAnotherReason() {
        // Unsupported system language: Icelandic system, Siri falls back to en-US; or a region-variant mismatch.
        let icelandic = guardian.evaluate(inputs(system: "is-IS", siri: "is-IS", answer: 2))
        XCTAssertEqual(icelandic.state, .protected)
        XCTAssertEqual(icelandic.ineligibilitySource, .other)
        XCTAssertEqual(guardian.evaluate(inputs(system: "en-GB", siri: "en-US", answer: 2)).ineligibilitySource, .other)
    }

    func testMissingInputsAreUnknownNotProtected() {
        XCTAssertEqual(guardian.evaluate(inputs(answer: nil)).state, .unknown)
        XCTAssertEqual(guardian.evaluate(inputs(siri: "pt-BR", answer: nil)).state, .unknown)
        var broken0 = inputs()
        broken0.autoSetConfiguration = nil
        XCTAssertEqual(guardian.evaluate(broken0).state, .unknown)
        var broken = inputs()
        broken.autoSetConfiguration = autoSet(selectors: 0, targets: 0, error: "unreadable")
        XCTAssertEqual(guardian.evaluate(broken).state, .unknown)
    }

    func testUnreadableInstalledStateFallsBackToModelCatalogSelection() {
        // With SIP enabled the asset folder is `restricted`, even with Full Disk Access (26B5091g, 2026-09-29).
        let protected = guardian.evaluate(inputs(installed: nil))
        XCTAssertEqual(protected.state, .protected)
        XCTAssertTrue(protected.reasons.contains { $0.contains("SIP-restricted") })
        XCTAssertEqual(guardian.evaluate(inputs(targets: 1, installed: nil)).state, .releasing)
        XCTAssertEqual(guardian.evaluate(inputs(answer: 4, installed: nil)).state, .atRisk)
    }

    // MARK: Plan: target selection for any system language

    func testDisableKeepsAnExistingMismatch() throws {
        let plan = try guardian.plan(.disable, context: context(system: "pt-BR", siri: "en-GB", installed: ["pt-BR", "en-GB"]), scope: .allDevices)
        XCTAssertEqual(plan.targetSiriLanguage, "en-GB")
        XCTAssertTrue(plan.noChangeNeeded)
        XCTAssertFalse(plan.scopeVerified)
    }

    func testDisablePrefersAnAlreadyInstalledLanguage() throws {
        let plan = try guardian.plan(.disable, context: context(system: "de-DE", siri: "de-DE", installed: ["de-DE", "fr-FR"]), scope: .thisMacOnly)
        XCTAssertEqual(plan.targetSiriLanguage, "fr-FR")
        XCTAssertEqual(plan.requiresSiriAssetDownload, false)
    }

    func testDisableOnEnglishSystemSkipsEveryEnglishVariant() throws {
        let plan = try guardian.plan(.disable, context: context(system: "en-GB", siri: "en-GB", installed: ["en-GB", "en-US"]), scope: .thisMacOnly)
        XCTAssertEqual(plan.targetSiriLanguage, "es-ES")
        XCTAssertEqual(plan.requiresSiriAssetDownload, true)
        XCTAssertTrue(plan.warnings.contains { $0.contains("will download them") })
    }

    func testDisableOnJapaneseSystemUsesEnglish() throws {
        let plan = try guardian.plan(.disable, context: context(system: "ja-JP", siri: "ja-JP", installed: ["ja-JP"]), scope: .thisMacOnly)
        XCTAssertEqual(plan.targetSiriLanguage, "en-US")
    }

    func testDisableRejectsUnsupportedOrSameBasePreferredLanguage() throws {
        XCTAssertThrowsError(try guardian.plan(.disable, context: context(system: "pt-BR", siri: "pt-BR"), scope: .thisMacOnly, preferredLanguage: "is-IS")) {
            XCTAssertEqual($0 as? AppleIntelligenceGuardError, .unsupportedSiriLanguage("is-IS"))
        }
        let sameBase = try guardian.plan(.disable, context: context(system: "pt-BR", siri: "pt-BR"), scope: .thisMacOnly, preferredLanguage: "pt-PT")
        XCTAssertEqual(sameBase.targetSiriLanguage, "en-US", "pt-PT shares the pt base language and cannot create the mismatch")
    }

    func testDisableWarnsWhenSiriIsOn() throws {
        let plan = try guardian.plan(.disable, context: context(system: "pt-BR", siri: "pt-BR", siriEnabled: true), scope: .thisMacOnly)
        XCTAssertTrue(plan.warnings.contains { $0.contains("Siri is on") })
    }

    func testDisableWithoutSupportedListStillPlansButWarns() throws {
        var ctx = context(system: "pt-BR", siri: "pt-BR")
        ctx.supportedSiriLanguages = nil
        let plan = try guardian.plan(.disable, context: ctx, scope: .thisMacOnly)
        XCTAssertEqual(plan.targetSiriLanguage, "en-US")
        XCTAssertTrue(plan.warnings.contains { $0.contains("not validated") })
    }

    func testEnableRestoresSavedSettingsNotSystemLanguage() throws {
        // English Mac whose user deliberately ran Siri in Spanish before disabling.
        let saved = SavedSiriSettings(siriLanguage: "es-MX", outputVoice: Data([7]), savedAt: Date(timeIntervalSince1970: 0))
        let plan = try guardian.plan(.enable, context: context(system: "en-US", siri: "fr-FR"), scope: .thisMacOnly, saved: saved)
        XCTAssertEqual(plan.targetSiriLanguage, "es-MX")
        XCTAssertEqual(plan.targetOutputVoice, Data([7]))
        XCTAssertTrue(plan.restoresSavedSettings)
    }

    func testEnableWithoutSavedSettingsUsesSystemOrSameBaseSiriLanguage() throws {
        XCTAssertEqual(try guardian.plan(.enable, context: context(system: "pt_BR", siri: "en-US"), scope: .thisMacOnly).targetSiriLanguage, "pt-BR")
        // A system locale Siri does not list exactly falls back to a supported variant of the same language.
        XCTAssertEqual(try guardian.plan(.enable, context: context(system: "es-AR", siri: "en-US"), scope: .thisMacOnly).targetSiriLanguage, "es-ES")
        XCTAssertThrowsError(try guardian.plan(.enable, context: context(system: "is-IS", siri: "en-US"), scope: .thisMacOnly))
        var ctx = context(system: "pt-BR", siri: "en-US")
        ctx.systemLanguage = nil
        XCTAssertThrowsError(try guardian.plan(.enable, context: ctx, scope: .thisMacOnly))
    }

    // MARK: Apply: save, verify, roll back

    func testDisableSavesOriginalSettingsAndVerifiesIneligibility() throws {
        let env = FakeSiriEnvironment(system: "pt-BR", siri: "pt-BR", voice: Data([9]), eligibility: mismatchRule(system: "pt-BR"))
        let plan = try guardian.plan(.disable, context: env.context(), scope: .thisMacOnly)
        let result = try guardian.apply(plan, environment: env, now: Date(timeIntervalSince1970: 1))
        XCTAssertTrue(result.executed)
        XCTAssertEqual(result.eligibilityAnswerAfter, 2)
        XCTAssertEqual(env.writes, ["en-US"])
        XCTAssertEqual(env.saved, SavedSiriSettings(siriLanguage: "pt-BR", outputVoice: Data([9]), savedAt: Date(timeIntervalSince1970: 1)))
    }

    func testDisableDoesNotOverwriteAnEarlierSave() throws {
        let env = FakeSiriEnvironment(system: "pt-BR", siri: "pt-BR", eligibility: mismatchRule(system: "pt-BR"))
        let original = SavedSiriSettings(siriLanguage: "pt-BR", outputVoice: Data([1]), savedAt: Date(timeIntervalSince1970: 0))
        env.saved = original
        _ = try guardian.apply(try guardian.plan(.disable, context: env.context(), scope: .thisMacOnly), environment: env)
        XCTAssertEqual(env.saved, original)
    }

    func testDisableRollsBackWhenAppleStaysEligible() throws {
        let env = FakeSiriEnvironment(system: "pt-BR", siri: "pt-BR", voice: Data([9]), eligibility: { _ in 4 })
        let plan = try guardian.plan(.disable, context: env.context(), scope: .thisMacOnly)
        XCTAssertThrowsError(try guardian.apply(plan, environment: env)) {
            XCTAssertEqual($0 as? AppleIntelligenceGuardError, .verificationFailed(answer: 4))
        }
        XCTAssertEqual(env.writes, ["en-US", "pt-BR"])
        XCTAssertEqual(env.ctx.siriLanguage, "pt-BR")
    }

    func testDisableRollsBackWhenEligibilityIsUnreadable() throws {
        let env = FakeSiriEnvironment(system: "pt-BR", siri: "pt-BR", eligibility: { _ in nil })
        XCTAssertThrowsError(try guardian.apply(try guardian.plan(.disable, context: env.context(), scope: .thisMacOnly), environment: env))
        XCTAssertEqual(env.ctx.siriLanguage, "pt-BR")
    }

    func testEnableRestoresAndClearsSavedSettings() throws {
        let env = FakeSiriEnvironment(system: "pt-BR", siri: "en-US", voice: Data([2]), eligibility: mismatchRule(system: "pt-BR"))
        env.saved = SavedSiriSettings(siriLanguage: "pt-BR", outputVoice: Data([9]), savedAt: Date(timeIntervalSince1970: 0))
        let plan = try guardian.plan(.enable, context: env.context(), scope: .thisMacOnly, saved: env.saved)
        let result = try guardian.apply(plan, environment: env)
        XCTAssertEqual(result.eligibilityAnswerAfter, 4)
        XCTAssertEqual(env.ctx.siriLanguage, "pt-BR")
        XCTAssertEqual(env.voice, Data([9]))
        XCTAssertNil(env.saved)
    }

    func testEnableOnIneligibleSystemDoesNotRollBack() throws {
        // Enable cannot force eligibility (e.g. unsupported region); it restores settings and reports the answer.
        let env = FakeSiriEnvironment(system: "pt-BR", siri: "en-US", eligibility: { _ in 2 })
        let result = try guardian.apply(try guardian.plan(.enable, context: env.context(), scope: .thisMacOnly), environment: env)
        XCTAssertEqual(result.eligibilityAnswerAfter, 2)
        XCTAssertEqual(env.writes, ["pt-BR"])
    }

    // MARK: Parsers

    func testParseEligibilityReadsSiriModeDomain() throws {
        let plist: [String: Any] = [
            "OS_ELIGIBILITY_DOMAIN_SIRI_MODE": [
                "os_eligibility_answer_t": 2,
                "status": ["OS_ELIGIBILITY_INPUT_DEVICE_AND_SIRI_LANGUAGE_MATCH": 2, "OS_ELIGIBILITY_INPUT_SIRI_LANGUAGE": 3],
            ],
            "OS_ELIGIBILITY_DOMAIN_XCODE_LLM": ["os_eligibility_answer_t": 4],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        let parsed = guardian.parseEligibility(data)
        XCTAssertEqual(parsed.answer, 2)
        XCTAssertEqual(parsed.languageMatch, 2)
        XCTAssertNil(guardian.parseEligibility(Data("not a plist".utf8)).answer)
    }

    func testInstalledAssetScansMatchExactSpecifiers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func asset(_ name: String, _ specifier: String) throws {
            let dir = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let info = ["MobileAssetProperties": ["AssetSpecifier": specifier]]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: dir.appendingPathComponent("Info.plist"))
        }
        try asset("a6e4.asset", AppleIntelligenceLanguageGuard.targetSpecifier)
        try asset("701c.asset", "com.apple.fm.language.instruct_3b.image_playground_edit_suggestions.generic_sparse")
        try asset("10b5.asset", "com.apple.siri.asr.assistant.pt_BR")
        try asset("124f.asset", "com.apple.siri.asr.assistant.en_US")
        try asset("33e2.asset", "com.apple.siri.nl.voc.pt_BR")
        XCTAssertEqual(AppleIntelligenceLanguageGuard.installedTargetAssets(directory: root.path), ["a6e4.asset"])
        XCTAssertEqual(AppleIntelligenceLanguageGuard.installedSiriLanguages(directory: root.path), ["en-US", "pt-BR"])
        XCTAssertNil(AppleIntelligenceLanguageGuard.installedTargetAssets(directory: root.appendingPathComponent("missing").path))
    }

    func testLiveSupportedSiriLanguagesAreReadableWithoutEntitlement() throws {
        let languages = try XCTUnwrap(LiveSiriLanguageEnvironment.supportedSiriLanguages())
        XCTAssertTrue(languages.contains("en-US"))
    }
}
