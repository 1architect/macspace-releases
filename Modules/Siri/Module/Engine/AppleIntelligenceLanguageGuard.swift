import Foundation
import MacSpacePlatform

/// Apple Intelligence off-switch via the Siri/system language mismatch (CP111, CP112).
///
/// macOS 27 makes Apple Intelligence ineligible when the Siri language differs from the
/// system language (`OS_ELIGIBILITY_DOMAIN_SIRI_MODE`, input `DEVICE_AND_SIRI_LANGUAGE_MATCH`).
/// ModelCatalog then stops selecting the 3B model and MobileAsset evicts it. The Siri language
/// is changed by writing `com.apple.assistant.backedup` "Session Language" and posting
/// `AFLanguageCodeDidChangeDarwinNotification`; the AFPreferences setter is entitlement-gated.
///
/// Apple's eligibility answer is authoritative. The language comparison only explains or
/// predicts it: a Mac can be ineligible for other reasons (unsupported system language or
/// region), and whether region variants such as en-GB/en-US count as a mismatch is unverified.

public enum AppleIntelligenceGuardState: String, Codable, Sendable {
    /// Apple Intelligence is ineligible and the 3B model is neither selected nor installed.
    case protected
    /// Ineligible, but the 3B model is still selected or installed; owner-side eviction is expected to follow.
    case releasing
    /// Eligibility says eligible; the 3B model may be (re)downloaded.
    case atRisk = "at-risk"
    /// A required input could not be read.
    case unknown
}

public enum AppleIntelligenceIneligibilitySource: String, Codable, Sendable {
    /// The Siri and system base languages differ (the MACSPACE method).
    case languageMismatch = "language-mismatch"
    /// Ineligible although the languages share a base language (unsupported language/region, or a region-variant mismatch).
    case other
}

public enum SiriLanguageSyncScope: String, Codable, Sendable, CaseIterable {
    case thisMacOnly = "this-mac-only"
    case allDevices = "all-devices"
}

public struct AppleIntelligenceGuardInputs: Codable, Sendable, Equatable {
    public var operatingSystemBuild: String?
    public var systemLanguage: String?
    public var siriLanguage: String?
    public var siriEnabled: Bool?
    /// `os_eligibility_answer_t` of the SIRI_MODE domain; 4 was observed as eligible, 2 as not eligible.
    public var siriModeAnswer: Int?
    public var languageMatchInput: Int?
    public var autoSetConfiguration: AutoSetConfigurationObservation?
    public var installedTargetAssets: [String]?

    public init(operatingSystemBuild: String? = nil, systemLanguage: String?, siriLanguage: String?, siriEnabled: Bool? = nil,
                siriModeAnswer: Int?, languageMatchInput: Int? = nil,
                autoSetConfiguration: AutoSetConfigurationObservation?, installedTargetAssets: [String]?) {
        self.operatingSystemBuild = operatingSystemBuild
        self.systemLanguage = systemLanguage
        self.siriLanguage = siriLanguage
        self.siriEnabled = siriEnabled
        self.siriModeAnswer = siriModeAnswer
        self.languageMatchInput = languageMatchInput
        self.autoSetConfiguration = autoSetConfiguration
        self.installedTargetAssets = installedTargetAssets
    }
}

public struct AppleIntelligenceGuardStatus: Codable, Sendable, Equatable {
    public let generatedAt: Date
    public let state: AppleIntelligenceGuardState
    public let ineligibilitySource: AppleIntelligenceIneligibilitySource?
    public let languagesMatch: Bool?
    public let eligible: Bool?
    public let targetSelected: Bool?
    public let targetInstalled: Bool?
    public let inputs: AppleIntelligenceGuardInputs
    public let reasons: [String]
}

/// The user's Siri settings before MACSPACE changed them, restored by `enable`.
public struct SavedSiriSettings: Codable, Sendable, Equatable {
    public let siriLanguage: String
    /// Binary property list of the "Output Voice" dictionary, restored verbatim.
    public let outputVoice: Data?
    public let savedAt: Date

    public init(siriLanguage: String, outputVoice: Data?, savedAt: Date) {
        self.siriLanguage = siriLanguage
        self.outputVoice = outputVoice
        self.savedAt = savedAt
    }
}

/// Facts the planner needs about the current Siri setup.
public struct SiriLanguageContext: Sendable, Equatable {
    public var systemLanguage: String?
    public var siriLanguage: String?
    public var siriEnabled: Bool?
    /// Siri's supported languages (AFPreferencesSupportedLanguages); nil when unreadable.
    public var supportedSiriLanguages: [String]?
    /// Languages whose Siri speech-recognition assets are already installed; nil when unreadable.
    public var installedSiriLanguages: [String]?

    public init(systemLanguage: String?, siriLanguage: String?, siriEnabled: Bool? = nil,
                supportedSiriLanguages: [String]?, installedSiriLanguages: [String]?) {
        self.systemLanguage = systemLanguage
        self.siriLanguage = siriLanguage
        self.siriEnabled = siriEnabled
        self.supportedSiriLanguages = supportedSiriLanguages
        self.installedSiriLanguages = installedSiriLanguages
    }
}

public struct SiriLanguageChangePlan: Codable, Sendable, Equatable {
    public enum Action: String, Codable, Sendable { case disable, enable }
    public let action: Action
    public let currentSiriLanguage: String?
    public let targetSiriLanguage: String
    /// Voice to write with the language; nil leaves the user's voice unchanged.
    public let targetOutputVoice: Data?
    public let systemLanguage: String
    public let scope: SiriLanguageSyncScope
    /// CP112 did not measure whether the preference syncs through iCloud, so neither scope is guaranteed yet.
    public let scopeVerified: Bool
    /// The target's Siri speech assets are not installed, so switching will download them (~1.5 GB observed for en-US).
    public let requiresSiriAssetDownload: Bool?
    public let restoresSavedSettings: Bool
    public let noChangeNeeded: Bool
    public let warnings: [String]
}

public struct SiriLanguageChangeResult: Codable, Sendable, Equatable {
    public let plan: SiriLanguageChangePlan
    public let executed: Bool
    public let eligibilityAnswerAfter: Int?
}

public enum AppleIntelligenceGuardError: Error, Equatable, CustomStringConvertible {
    case systemLanguageUnavailable
    case siriLanguageUnavailable
    case noMismatchedLanguageAvailable(system: String)
    case unsupportedSiriLanguage(String)
    case preferenceWriteFailed
    case verificationFailed(answer: Int?)

    public var description: String {
        switch self {
        case .systemLanguageUnavailable: return "The system language could not be read."
        case .siriLanguageUnavailable: return "The current Siri language could not be read."
        case .noMismatchedLanguageAvailable(let system): return "No supported Siri language with a base language different from \(system) is available."
        case .unsupportedSiriLanguage(let code): return "\(code) is not a supported Siri language."
        case .preferenceWriteFailed: return "Writing the Siri language preference failed."
        case .verificationFailed(let answer): return "Apple Intelligence stayed eligible (answer \(answer.map(String.init) ?? "unreadable")) after the change; the previous Siri settings were restored."
        }
    }
}

/// Everything the guard reads from or writes to the system, injectable for tests.
public protocol SiriLanguageEnvironment {
    func context() -> SiriLanguageContext
    func outputVoice() -> Data?
    func eligibilityAnswer() -> Int?
    func write(siriLanguage: String, outputVoice: Data?) throws
    func loadSavedSettings() -> SavedSiriSettings?
    func saveSettings(_ settings: SavedSiriSettings?) throws
    func sleep(seconds: Double)
}

public struct AppleIntelligenceLanguageGuard {
    public static let siriPreferencesDomain = "com.apple.assistant.backedup"
    public static let siriLanguageKey = "Session Language"
    public static let outputVoiceKey = "Output Voice"
    public static let siriEnabledDomain = "com.apple.assistant.support"
    public static let siriEnabledKey = "Assistant Enabled"
    public static let languageChangeNotification = "AFLanguageCodeDidChangeDarwinNotification"
    public static let eligibilityPath = "/private/var/db/os_eligibility/eligibility.plist"
    public static let siriModeDomain = "OS_ELIGIBILITY_DOMAIN_SIRI_MODE"
    public static let languageMatchInputKey = "OS_ELIGIBILITY_INPUT_DEVICE_AND_SIRI_LANGUAGE_MATCH"
    public static let eligibleAnswer = 4
    public static let generativeModelsAssetDirectory = "/System/Library/AssetsV2/com_apple_MobileAsset_UAF_FM_GenerativeModels/purpose_auto"
    public static let siriUnderstandingAssetDirectory = "/System/Library/AssetsV2/com_apple_MobileAsset_UAF_Siri_Understanding/purpose_auto"
    public static let siriASRSpecifierPrefix = "com.apple.siri.asr.assistant."
    public static let targetSpecifier = "com.apple.fm.language.instruct_3b.base.generic_sparse"
    /// Fallback mismatch candidates, used after the current Siri language and installed languages.
    public static let defaultDisableLanguages = ["en-US", "es-ES", "fr-FR", "de-DE", "ja-JP"]

    public init() {}

    // MARK: Pure evaluation

    public static func normalize(_ identifier: String) -> String { identifier.replacingOccurrences(of: "_", with: "-") }

    /// Base language comparison, matching Apple's `system: pt, siri: en` reporting.
    public static func baseLanguage(_ identifier: String) -> String {
        let normalized = normalize(identifier)
        if let code = Locale(identifier: normalized).language.languageCode?.identifier { return code.lowercased() }
        return normalized.split(separator: "-").first.map { $0.lowercased() } ?? normalized.lowercased()
    }

    public func evaluate(_ inputs: AppleIntelligenceGuardInputs, now: Date = Date()) -> AppleIntelligenceGuardStatus {
        var reasons: [String] = []
        var languagesMatch: Bool?
        if let system = inputs.systemLanguage, let siri = inputs.siriLanguage {
            let match = Self.baseLanguage(system) == Self.baseLanguage(siri)
            languagesMatch = match
            reasons.append(match ? "Siri language \(siri) shares the base language of system language \(system)."
                                 : "Siri language \(siri) differs from system language \(system).")
        } else {
            reasons.append("System or Siri language could not be read.")
        }
        let eligible = inputs.siriModeAnswer.map { $0 == Self.eligibleAnswer }
        switch eligible {
        case .some(true): reasons.append("Apple Intelligence eligibility (SIRI_MODE) is eligible.")
        case .some(false): reasons.append("Apple Intelligence eligibility (SIRI_MODE) is not eligible (answer \(inputs.siriModeAnswer!)).")
        case .none: reasons.append("Apple Intelligence eligibility (SIRI_MODE) could not be read.")
        }
        var targetSelected: Bool?
        if let autoSet = inputs.autoSetConfiguration, autoSet.error == nil, let count = autoSet.targetCount {
            targetSelected = count > 0
            reasons.append("ModelCatalog AutoSet configuration has \(autoSet.selectorCount ?? 0) selectors, \(count) for the 3B model.")
        } else {
            reasons.append("ModelCatalog AutoSet configuration could not be read.")
        }
        let targetInstalled = inputs.installedTargetAssets.map { !$0.isEmpty }
        if let installed = targetInstalled { reasons.append(installed ? "The 3B model is installed." : "The 3B model is not installed.") }
        else { reasons.append("Installed Foundation Model assets could not be read.") }

        var state = AppleIntelligenceGuardState.unknown
        var source: AppleIntelligenceIneligibilitySource?
        switch eligible {
        case .some(true):
            state = .atRisk
            if languagesMatch == false {
                reasons.append("The languages differ but Apple still reports eligible; the mismatch method may not apply on this build.")
            }
        case .some(false):
            source = languagesMatch == false ? .languageMismatch : .other
            if source == .other {
                reasons.append("Apple Intelligence is ineligible for a reason other than a base-language mismatch (for example an unsupported language or region).")
            }
            if let selected = targetSelected, let installed = targetInstalled {
                state = (selected || installed) ? .releasing : .protected
            } else if let selected = targetSelected {
                // With SIP enabled the Foundation Model asset folder is `restricted` and unreadable even with Full Disk
                // Access; ModelCatalog's selection is then the best signal (CP111: eviction followed deselection).
                state = selected ? .releasing : .protected
                reasons.append("Installed model state is unreadable (SIP-restricted); relying on ModelCatalog's selection.")
            }
        case .none:
            if languagesMatch == true { reasons.append("Matching languages suggest Apple Intelligence may be eligible.") }
        }
        return AppleIntelligenceGuardStatus(generatedAt: now, state: state, ineligibilitySource: source,
                                            languagesMatch: languagesMatch, eligible: eligible,
                                            targetSelected: targetSelected, targetInstalled: targetInstalled,
                                            inputs: inputs, reasons: reasons)
    }

    public func plan(_ action: SiriLanguageChangePlan.Action, context: SiriLanguageContext, scope: SiriLanguageSyncScope,
                     preferredLanguage: String? = nil, saved: SavedSiriSettings? = nil) throws -> SiriLanguageChangePlan {
        guard let system = context.systemLanguage.map(Self.normalize), !system.isEmpty else { throw AppleIntelligenceGuardError.systemLanguageUnavailable }
        let systemBase = Self.baseLanguage(system)
        let supported = context.supportedSiriLanguages?.map(Self.normalize)
        let installed = context.installedSiriLanguages?.map(Self.normalize)
        let current = context.siriLanguage.map(Self.normalize)
        func isSupported(_ code: String) -> Bool { supported?.contains(code) ?? true }

        var warnings: [String] = []
        let target: String
        var voice: Data?
        var restores = false
        switch action {
        case .disable:
            if let preferred = preferredLanguage.map(Self.normalize), !isSupported(preferred) {
                throw AppleIntelligenceGuardError.unsupportedSiriLanguage(preferred)
            }
            let candidates = [preferredLanguage.map(Self.normalize), current].compactMap { $0 }
                + (installed ?? []) + Self.defaultDisableLanguages
            guard let choice = candidates.first(where: { Self.baseLanguage($0) != systemBase && isSupported($0) }) else {
                throw AppleIntelligenceGuardError.noMismatchedLanguageAvailable(system: system)
            }
            target = choice
            warnings.append("Apple Intelligence becomes unavailable.")
            if context.siriEnabled == true {
                warnings.append("Siri is on: it will listen for and answer in \(target), and your Siri voice is left unchanged.")
            }
        case .enable:
            if let saved {
                target = Self.normalize(saved.siriLanguage)
                voice = saved.outputVoice
                restores = true
            } else if isSupported(system) {
                target = system
            } else if let sameBase = supported?.first(where: { Self.baseLanguage($0) == systemBase }) {
                target = sameBase
            } else {
                throw AppleIntelligenceGuardError.unsupportedSiriLanguage(system)
            }
            warnings.append("Apple Intelligence may become eligible again; macOS may download the ~12 GB 3B model.")
        }
        if supported == nil { warnings.append("Siri's supported-language list could not be read; \(target) was not validated.") }
        let needsDownload = installed.map { !$0.contains(target) }
        if needsDownload == true { warnings.append("Siri speech assets for \(target) are not installed; macOS will download them (~1.5 GB observed for en-US).") }
        warnings.append("Whether this preference syncs to other devices through iCloud is unverified (CP112); the \(scope.rawValue) choice is recorded but not guaranteed.")
        let unchanged = current == target && voice == nil
        return SiriLanguageChangePlan(action: action, currentSiriLanguage: current, targetSiriLanguage: target,
                                      targetOutputVoice: voice, systemLanguage: system, scope: scope, scopeVerified: false,
                                      requiresSiriAssetDownload: needsDownload, restoresSavedSettings: restores,
                                      noChangeNeeded: unchanged, warnings: warnings)
    }

    /// Applies a plan, then waits for eligibility. A disable that leaves Apple Intelligence eligible is rolled back.
    public func apply(_ plan: SiriLanguageChangePlan, environment: any SiriLanguageEnvironment,
                      timeout: Double = 8, pollInterval: Double = 0.5, now: Date = Date()) throws -> SiriLanguageChangeResult {
        if plan.noChangeNeeded {
            if plan.action == .enable { try environment.saveSettings(nil) }
            return SiriLanguageChangeResult(plan: plan, executed: false, eligibilityAnswerAfter: environment.eligibilityAnswer())
        }
        let previousLanguage = environment.context().siriLanguage
        let previousVoice = environment.outputVoice()
        if plan.action == .disable, environment.loadSavedSettings() == nil {
            guard let previousLanguage else { throw AppleIntelligenceGuardError.siriLanguageUnavailable }
            try environment.saveSettings(SavedSiriSettings(siriLanguage: previousLanguage, outputVoice: previousVoice, savedAt: now))
        }
        try environment.write(siriLanguage: plan.targetSiriLanguage, outputVoice: plan.targetOutputVoice)

        var answer = environment.eligibilityAnswer()
        var waited = 0.0
        while waited < timeout {
            if plan.action == .disable, let value = answer, value != Self.eligibleAnswer { break }
            if plan.action == .enable, answer == Self.eligibleAnswer { break }
            environment.sleep(seconds: pollInterval)
            waited += pollInterval
            answer = environment.eligibilityAnswer()
        }
        switch plan.action {
        case .disable where answer == nil || answer == Self.eligibleAnswer:
            if let previousLanguage { try environment.write(siriLanguage: previousLanguage, outputVoice: previousVoice) }
            throw AppleIntelligenceGuardError.verificationFailed(answer: answer)
        case .enable:
            try environment.saveSettings(nil)
        default:
            break
        }
        return SiriLanguageChangeResult(plan: plan, executed: true, eligibilityAnswerAfter: answer)
    }

    /// Parses the SIRI_MODE answer and language-match input from os_eligibility's plist.
    public func parseEligibility(_ data: Data) -> (answer: Int?, languageMatch: Int?) {
        guard let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let domain = root[Self.siriModeDomain] as? [String: Any] else { return (nil, nil) }
        let answer = (domain["os_eligibility_answer_t"] as? NSNumber)?.intValue
        let match = ((domain["status"] as? [String: Any])?[Self.languageMatchInputKey] as? NSNumber)?.intValue
        return (answer, match)
    }

    // MARK: Live reads

    public func readInputs(fileManager: FileManager = .default, runner: any CommandRunning = ProcessCommandRunner(defaultTimeout: 10)) -> AppleIntelligenceGuardInputs {
        let eligibility = (try? Data(contentsOf: URL(fileURLWithPath: Self.eligibilityPath))).map(parseEligibility)
        let build = (try? runner.run("/usr/bin/sw_vers", ["-buildVersion"])).flatMap {
            $0.exitCode == 0 ? String(decoding: $0.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) : nil
        }
        let context = LiveSiriLanguageEnvironment(fileManager: fileManager).context()
        return AppleIntelligenceGuardInputs(
            operatingSystemBuild: build, systemLanguage: context.systemLanguage, siriLanguage: context.siriLanguage,
            siriEnabled: context.siriEnabled, siriModeAnswer: eligibility?.answer, languageMatchInput: eligibility?.languageMatch,
            autoSetConfiguration: AutoSetConfigurationInspector(fileManager: fileManager).inspect(),
            installedTargetAssets: Self.installedTargetAssets(fileManager: fileManager)
        )
    }

    public func status(now: Date = Date()) -> AppleIntelligenceGuardStatus { evaluate(readInputs(), now: now) }

    /// Specifiers of installed assets in an AssetsV2 `purpose_auto` directory.
    public static func installedSpecifiers(fileManager: FileManager = .default, directory: String) -> [String: String]? {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory) else { return nil }
        var result: [String: String] = [:]
        for name in names where name.hasSuffix(".asset") {
            guard let data = fileManager.contents(atPath: "\(directory)/\(name)/Info.plist"),
                  let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                  let specifier = (plist["MobileAssetProperties"] as? [String: Any])?["AssetSpecifier"] as? String else { continue }
            result[name] = specifier
        }
        return result
    }

    /// Directory names of installed assets whose specifier is the exact 3B target.
    public static func installedTargetAssets(fileManager: FileManager = .default, directory: String = generativeModelsAssetDirectory) -> [String]? {
        installedSpecifiers(fileManager: fileManager, directory: directory).map { $0.filter { $0.value == targetSpecifier }.keys.sorted() }
    }

    /// Siri languages whose speech-recognition assets are installed, e.g. `com.apple.siri.asr.assistant.en_US` -> en-US.
    public static func installedSiriLanguages(fileManager: FileManager = .default, directory: String = siriUnderstandingAssetDirectory) -> [String]? {
        installedSpecifiers(fileManager: fileManager, directory: directory).map { specifiers in
            Array(Set(specifiers.values.filter { $0.hasPrefix(siriASRSpecifierPrefix) }
                .map { normalize(String($0.dropFirst(siriASRSpecifierPrefix.count))) })).sorted()
        }
    }
}

/// Live system implementation. Reads use CFPreferences and world-readable files; writes use the CP112 method.
public struct LiveSiriLanguageEnvironment: SiriLanguageEnvironment {
    public static let savedSettingsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/MACSPACE/ai-guard-saved-siri-settings.json")
    private let fileManager: FileManager
    private let savedURL: URL

    public init(fileManager: FileManager = .default, savedSettingsURL: URL = LiveSiriLanguageEnvironment.savedSettingsURL) {
        self.fileManager = fileManager
        self.savedURL = savedSettingsURL
    }

    private func value(_ key: String, _ domain: String) -> Any? {
        CFPreferencesAppSynchronize(domain as CFString)
        return CFPreferencesCopyAppValue(key as CFString, domain as CFString)
    }

    public func context() -> SiriLanguageContext {
        let guardType = AppleIntelligenceLanguageGuard.self
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        let system = (CFPreferencesCopyAppValue("AppleLanguages" as CFString, kCFPreferencesAnyApplication) as? [String])?.first
        return SiriLanguageContext(
            systemLanguage: system,
            siriLanguage: value(guardType.siriLanguageKey, guardType.siriPreferencesDomain) as? String,
            siriEnabled: (value(guardType.siriEnabledKey, guardType.siriEnabledDomain) as? NSNumber)?.boolValue,
            supportedSiriLanguages: Self.supportedSiriLanguages(),
            installedSiriLanguages: guardType.installedSiriLanguages(fileManager: fileManager)
        )
    }

    public func outputVoice() -> Data? {
        guard let voice = value(AppleIntelligenceLanguageGuard.outputVoiceKey, AppleIntelligenceLanguageGuard.siriPreferencesDomain) else { return nil }
        return try? PropertyListSerialization.data(fromPropertyList: voice, format: .binary, options: 0)
    }

    public func eligibilityAnswer() -> Int? {
        (try? Data(contentsOf: URL(fileURLWithPath: AppleIntelligenceLanguageGuard.eligibilityPath)))
            .flatMap { AppleIntelligenceLanguageGuard().parseEligibility($0).answer }
    }

    public func write(siriLanguage: String, outputVoice: Data?) throws {
        let domain = AppleIntelligenceLanguageGuard.siriPreferencesDomain as CFString
        CFPreferencesSetAppValue(AppleIntelligenceLanguageGuard.siriLanguageKey as CFString, siriLanguage as CFString, domain)
        if let outputVoice, let voice = try? PropertyListSerialization.propertyList(from: outputVoice, options: [], format: nil) {
            CFPreferencesSetAppValue(AppleIntelligenceLanguageGuard.outputVoiceKey as CFString, voice as CFPropertyList, domain)
        }
        guard CFPreferencesAppSynchronize(domain) else { throw AppleIntelligenceGuardError.preferenceWriteFailed }
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(AppleIntelligenceLanguageGuard.languageChangeNotification as CFString),
                                             nil, nil, true)
    }

    public func loadSavedSettings() -> SavedSiriSettings? {
        guard let data = try? Data(contentsOf: savedURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SavedSiriSettings.self, from: data)
    }

    public func saveSettings(_ settings: SavedSiriSettings?) throws {
        guard let settings else {
            if fileManager.fileExists(atPath: savedURL.path) { try fileManager.removeItem(at: savedURL) }
            return
        }
        try fileManager.createDirectory(at: savedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: savedURL, options: .atomic)
    }

    public func sleep(seconds: Double) { Thread.sleep(forTimeInterval: seconds) }

    /// Siri's supported languages from AssistantServices (`AFPreferencesSupportedLanguages`, readable without entitlements).
    public static func supportedSiriLanguages() -> [String]? {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/AssistantServices.framework/AssistantServices", RTLD_LAZY),
              let symbol = dlsym(handle, "AFPreferencesSupportedLanguages") else { return nil }
        typealias SupportedLanguages = @convention(c) () -> Unmanaged<CFArray>?
        guard let array = unsafeBitCast(symbol, to: SupportedLanguages.self)()?.takeUnretainedValue() as? [String] else { return nil }
        return array.map(AppleIntelligenceLanguageGuard.normalize)
    }
}
