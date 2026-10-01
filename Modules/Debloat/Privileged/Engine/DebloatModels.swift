import Foundation

/// Debloat product model: a catalog of controls, each made of primitive settings (a preference key or a
/// launchd override), an optional effect check.
///
/// The JSON produced from these types is the contract for the MACSPACE app. Bump `DebloatSchema.version`
/// on any incompatible change.
public enum DebloatSchema {
    public static let version = 1
}

// MARK: - Values

/// A property-list scalar that a control reads or writes.
public enum PlistValue: Codable, Equatable, Sendable, CustomStringConvertible {
    case bool(Bool)
    case int(Int)
    case string(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int.self) { self = .int(value) }
        else { self = .string(try container.decode(String.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }

    /// Converts a property-list object; nil for types controls never write (dates, data, collections, reals).
    public init?(propertyList object: Any) {
        if let number = object as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { self = .bool(number.boolValue) }
            else if CFNumberIsFloatType(number) { return nil }
            else { self = .int(number.intValue) }
        } else if let string = object as? String {
            self = .string(string)
        } else {
            return nil
        }
    }

    /// Equality that treats a boolean and its 0/1 integer spelling as the same preference value.
    public func matches(_ other: PlistValue) -> Bool {
        switch (self, other) {
        case let (.bool(bool), .int(int)), let (.int(int), .bool(bool)): return int == (bool ? 1 : 0)
        default: return self == other
        }
    }

    /// Arguments for `defaults write <domain> <key> ...`.
    public var defaultsWriteArguments: [String] {
        switch self {
        case .bool(let value): return ["-bool", value ? "true" : "false"]
        case .int(let value): return ["-int", String(value)]
        case .string(let value): return ["-string", value]
        }
    }

    public var description: String {
        switch self {
        case .bool(let value): return value ? "true" : "false"
        case .int(let value): return String(value)
        case .string(let value): return "\"\(value)\""
        }
    }
}

/// The observed or target state of one setting.
public enum SettingValue: Codable, Equatable, Sendable, CustomStringConvertible {
    /// Preference key missing, or no launchd override recorded for the label.
    case absent
    case value(PlistValue)
    /// An explicit `launchctl disable` (true) or `launchctl enable` (false) override.
    case launchdOverride(disabled: Bool)

    private enum CodingKeys: String, CodingKey { case kind, value, disabled }
    private enum Kind: String, Codable { case absent, value, launchdOverride }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .absent: self = .absent
        case .value: self = .value(try container.decode(PlistValue.self, forKey: .value))
        case .launchdOverride: self = .launchdOverride(disabled: try container.decode(Bool.self, forKey: .disabled))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .absent:
            try container.encode(Kind.absent, forKey: .kind)
        case .value(let value):
            try container.encode(Kind.value, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .launchdOverride(let disabled):
            try container.encode(Kind.launchdOverride, forKey: .kind)
            try container.encode(disabled, forKey: .disabled)
        }
    }

    public func matches(_ other: SettingValue) -> Bool {
        if case .value(let lhs) = self, case .value(let rhs) = other { return lhs.matches(rhs) }
        return self == other
    }

    public var description: String {
        switch self {
        case .absent: return "unset"
        case .value(let value): return value.description
        case .launchdOverride(let disabled): return disabled ? "disabled" : "enabled"
        }
    }
}

// MARK: - Settings

/// Who has to run a step. User preferences must be written as the user (under sudo they would land in
/// root's domain); system files and the system launchd domain need root.
public enum DebloatPrivilege: String, Codable, Sendable {
    case user
    case root
}

public struct PreferenceSetting: Codable, Equatable, Sendable {
    public enum Scope: String, Codable, Sendable {
        /// `defaults write <domain>` as the logged-in user.
        case user
        /// `defaults -currentHost write <domain>`.
        case currentHost
        /// An absolute plist path (without `.plist`) owned by root.
        case systemFile
    }

    public let scope: Scope
    public let domain: String
    public let key: String
    public let desired: PlistValue
    /// The value restored when MACSPACE has no journal entry for this key. nil means the macOS default is not
    /// known (for example, chosen in Setup Assistant), so revert needs a journal entry.
    public let fallback: SettingValue?

    public init(scope: Scope, domain: String, key: String, desired: PlistValue, fallback: SettingValue?) {
        self.scope = scope
        self.domain = domain
        self.key = key
        self.desired = desired
        self.fallback = fallback
    }
}

public struct LaunchdServiceSetting: Codable, Equatable, Sendable {
    public enum Domain: String, Codable, Sendable {
        /// `system/<label>`, a LaunchDaemon.
        case system
        /// `gui/<uid>/<label>`, a LaunchAgent in the user's login session.
        case gui
    }

    public let domain: Domain
    public let label: String

    public init(domain: Domain, label: String) {
        self.domain = domain
        self.label = label
    }
}

/// An admin override in `/Library/Preferences/FeatureFlags/Domain/<domain>.plist`, read by libfeatureflags at boot.
public struct FeatureFlagSetting: Codable, Equatable, Sendable {
    public static let overrideDirectory = "/Library/Preferences/FeatureFlags/Domain"
    public let domain: String
    public let feature: String
    /// The debloated value of the flag.
    public let enabled: Bool

    public init(domain: String, feature: String, enabled: Bool) {
        self.domain = domain
        self.feature = feature
        self.enabled = enabled
    }

    public var overridePath: String { "\(Self.overrideDirectory)/\(domain).plist" }
}

/// A value forced through a configuration profile payload. The payload type is also the preference domain.
public struct ManagedPreferenceSetting: Codable, Equatable, Sendable {
    public let payloadType: String
    public let key: String
    public let desired: PlistValue

    public init(payloadType: String, key: String, desired: PlistValue) {
        self.payloadType = payloadType
        self.key = key
        self.desired = desired
    }
}

/// A switch exposed by an Apple command-line tool that persists its own state.
public struct SystemToolSetting: Codable, Equatable, Sendable {
    public enum Tool: String, Codable, Sendable {
        /// `tailspin enable|disable`: the continuous kernel trace buffer. Persists across reboots and upgrades (tailspin(1)).
        case tailspin
        /// `mdutil -a -i on|off`: Spotlight indexing on all volumes.
        case spotlightIndexing
    }
    public let tool: Tool
    /// The debloated state.
    public let enabled: Bool

    public init(tool: Tool, enabled: Bool) {
        self.tool = tool
        self.enabled = enabled
    }
}

public struct ControlSetting: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case preference, launchdService, featureFlag, managedPreference, systemTool }

    /// Stable identifier, used by the journal: `pref:<scope>:<domain>:<key>`, `launchd:<domain>:<label>`,
    /// `flag:<domain>/<feature>` or `managed:<payloadType>:<key>`.
    public let id: String
    public let kind: Kind
    public let preference: PreferenceSetting?
    public let launchd: LaunchdServiceSetting?
    public let featureFlag: FeatureFlagSetting?
    public let managed: ManagedPreferenceSetting?
    public let tool: SystemToolSetting?

    init(id: String, kind: Kind, preference: PreferenceSetting? = nil, launchd: LaunchdServiceSetting? = nil,
         featureFlag: FeatureFlagSetting? = nil, managed: ManagedPreferenceSetting? = nil, tool: SystemToolSetting? = nil) {
        self.id = id
        self.kind = kind
        self.preference = preference
        self.launchd = launchd
        self.featureFlag = featureFlag
        self.managed = managed
        self.tool = tool
    }

    public static func preference(_ scope: PreferenceSetting.Scope, _ domain: String, _ key: String,
                                  desired: PlistValue, fallback: SettingValue?) -> ControlSetting {
        let setting = PreferenceSetting(scope: scope, domain: domain, key: key, desired: desired, fallback: fallback)
        return ControlSetting(id: "pref:\(scope.rawValue):\(domain):\(key)", kind: .preference, preference: setting)
    }

    public static func service(_ domain: LaunchdServiceSetting.Domain, _ label: String) -> ControlSetting {
        ControlSetting(id: "launchd:\(domain.rawValue):\(label)", kind: .launchdService,
                       launchd: LaunchdServiceSetting(domain: domain, label: label))
    }

    public static func flag(_ domain: String, _ feature: String, enabled: Bool = false) -> ControlSetting {
        ControlSetting(id: "flag:\(domain)/\(feature)", kind: .featureFlag,
                       featureFlag: FeatureFlagSetting(domain: domain, feature: feature, enabled: enabled))
    }

    public static func managed(_ payloadType: String, _ key: String, desired: PlistValue) -> ControlSetting {
        ControlSetting(id: "managed:\(payloadType):\(key)", kind: .managedPreference,
                       managed: ManagedPreferenceSetting(payloadType: payloadType, key: key, desired: desired))
    }

    public static func tool(_ tool: SystemToolSetting.Tool, enabled: Bool = false) -> ControlSetting {
        ControlSetting(id: "tool:\(tool.rawValue)", kind: .systemTool, tool: SystemToolSetting(tool: tool, enabled: enabled))
    }

    public var privilege: DebloatPrivilege {
        switch kind {
        case .preference: return preference?.scope == .systemFile ? .root : .user
        case .launchdService: return launchd?.domain == .system ? .root : .user
        case .featureFlag, .systemTool: return .root
        // The profile is generated and opened as the user, who approves it in System Settings.
        case .managedPreference: return .user
        }
    }

    public var desiredValue: SettingValue {
        switch kind {
        case .preference: return .value(preference!.desired)
        case .launchdService: return .launchdOverride(disabled: true)
        case .featureFlag: return .value(.bool(featureFlag!.enabled))
        case .managedPreference: return .value(managed!.desired)
        case .systemTool: return .value(.bool(tool!.enabled))
        }
    }

    /// Value restored when no journal entry exists. A service falls back to "no override", which the planner
    /// turns into an explicit `enable` because launchd has no command that removes an override.
    public var fallbackValue: SettingValue? {
        switch kind {
        case .preference: return preference?.fallback
        case .launchdService, .featureFlag, .managedPreference: return .absent
        // Both tools ship enabled.
        case .systemTool: return .value(.bool(true))
        }
    }

    public var summary: String {
        switch kind {
        case .preference:
            let p = preference!
            return "\(p.scope == .currentHost ? "currentHost " : "")\(p.domain) \(p.key)"
        case .launchdService:
            return "\(launchd!.domain.rawValue)/\(launchd!.label)"
        case .featureFlag:
            return "feature flag \(featureFlag!.domain)/\(featureFlag!.feature)"
        case .managedPreference:
            return "profile \(managed!.payloadType) \(managed!.key)"
        case .systemTool:
            return tool!.tool == .tailspin ? "tailspin" : "Spotlight indexing (all volumes)"
        }
    }
}

// MARK: - Controls

public enum ControlCategory: String, Codable, Sendable, CaseIterable {
    case telemetry
    case advertising
    case siri
    case appleIntelligence
    case suggestions
    case experiments
    case backgroundAnalysis
    case appServices
    case diagnostics
}

/// How a control acts, from most to least supported (see docs/debloat-app-evaluation.md).
public enum ControlMechanism: String, Codable, Sendable {
    case userPreference
    case systemPreference
    case launchdOverride
    /// An admin feature-flag override, read at boot.
    case featureFlag
    /// Managed preferences in a configuration profile the user approves in System Settings.
    case configurationProfile
    /// A persistent switch in an Apple command-line tool (tailspin, mdutil).
    case systemTool
    /// A build-specific private method applied by a dedicated module.
    case privateSurface
}

public enum ControlRisk: String, Codable, Sendable {
    case low
    case medium
    case high
}

public enum RestartRequirement: String, Codable, Sendable {
    case none
    case appRelaunch
    case logout
    case reboot
}

public struct EffectCheck: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Diagnostics submission stops advancing after the control is applied.
        case diagnosticSubmission
        /// The listed executables are not running.
        case processesAbsent
    }

    public let kind: Kind
    /// Executable paths for `processesAbsent`.
    public let executables: [String]?

    public static let diagnosticSubmission = EffectCheck(kind: .diagnosticSubmission, executables: nil)
    public static func processesAbsent(_ executables: [String]) -> EffectCheck {
        EffectCheck(kind: .processesAbsent, executables: executables)
    }
}

public struct DebloatControl: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let summary: String
    public let category: ControlCategory
    public let mechanism: ControlMechanism
    public let risk: ControlRisk
    public let restart: RestartRequirement
    public let settings: [ControlSetting]
    public let effect: EffectCheck?
    /// Features that stop working while the control is applied.
    public let breaks: [String]
    public let notes: [String]
    /// Builds on which a before/after experiment showed the effect. Apply is refused elsewhere unless the
    /// caller explicitly allows unverified controls.
    public let validatedBuilds: [String]
    /// Builds on which the control was measured to have no effect while SIP is enabled (e.g. launchd clears the
    /// override whenever the login session starts). Apply is refused there and the effect is `notControllable`.
    public let ineffectiveWithSIPBuilds: [String]
    /// The System Settings pane that shows the same option, for a deep link in the app.
    public let settingsURL: String?
    /// For `privateSurface` controls: the command that applies the control.
    public let applyCommand: String?
    /// A control that achieves the same goal where this one cannot take effect (e.g. a profile instead of launchd).
    public let replacedBy: String?

    public init(id: String, title: String, summary: String, category: ControlCategory, mechanism: ControlMechanism,
                risk: ControlRisk, restart: RestartRequirement, settings: [ControlSetting], effect: EffectCheck? = nil,
                breaks: [String] = [], notes: [String] = [], validatedBuilds: [String] = [],
                ineffectiveWithSIPBuilds: [String] = [],
                settingsURL: String? = nil, applyCommand: String? = nil, replacedBy: String? = nil) {
        self.id = id
        self.title = title
        self.summary = summary
        self.category = category
        self.mechanism = mechanism
        self.risk = risk
        self.restart = restart
        self.settings = settings
        self.effect = effect
        self.breaks = breaks
        self.notes = notes
        self.validatedBuilds = validatedBuilds
        self.ineffectiveWithSIPBuilds = ineffectiveWithSIPBuilds
        self.settingsURL = settingsURL
        self.applyCommand = applyCommand
        self.replacedBy = replacedBy
    }
}

// MARK: - Environment

public enum SIPState: String, Codable, Sendable {
    case enabled
    case disabled
    case custom
    case unknown
}

public extension DebloatControl {
    /// Whether measurements show the control cannot take effect on this system.
    func measuredIneffective(in environment: DebloatEnvironment) -> Bool {
        environment.sip == .enabled && environment.build.map(ineffectiveWithSIPBuilds.contains) == true
    }
}

public struct DebloatEnvironment: Codable, Equatable, Sendable {
    public var productVersion: String?
    public var build: String?
    /// Beta/seed build: a four-digit build number with a lowercase suffix (e.g. 26B5091g), or SeedAutoSubmit set.
    public var isPrerelease: Bool?
    public var sip: SIPState
    public var mdmEnrolled: Bool?
    public var depEnrolled: Bool?
    public var architecture: String?
    public var userName: String
    public var uid: UInt32
    public var runningAsRoot: Bool
    /// Whether this process can read TCC-protected data (checked by opening the user's TCC database).
    public var fullDiskAccess: Bool?
    /// Kernel boot time; the system launchd domain is rebuilt from here.
    public var bootedAt: Date?
    /// Start of the target user's login session (their loginwindow); the gui launchd domain is rebuilt from here.
    public var sessionStartedAt: Date?

    public init(productVersion: String?, build: String?, isPrerelease: Bool?, sip: SIPState, mdmEnrolled: Bool?,
                depEnrolled: Bool?, architecture: String?, userName: String, uid: UInt32, runningAsRoot: Bool,
                fullDiskAccess: Bool?, bootedAt: Date? = nil, sessionStartedAt: Date? = nil) {
        self.productVersion = productVersion
        self.build = build
        self.isPrerelease = isPrerelease
        self.sip = sip
        self.mdmEnrolled = mdmEnrolled
        self.depEnrolled = depEnrolled
        self.architecture = architecture
        self.userName = userName
        self.uid = uid
        self.runningAsRoot = runningAsRoot
        self.fullDiskAccess = fullDiskAccess
        self.bootedAt = bootedAt
        self.sessionStartedAt = sessionStartedAt
    }

    /// When the restart a control needs last happened; changes made after it are still pending.
    public func lastRestart(for requirement: RestartRequirement) -> Date? {
        switch requirement {
        case .reboot: return bootedAt
        case .logout: return sessionStartedAt ?? bootedAt
        case .none, .appRelaunch: return nil
        }
    }

    public var privilege: DebloatPrivilege { runningAsRoot ? .root : .user }
}

// MARK: - Status

public enum SettingAvailability: String, Codable, Sendable {
    case available
    /// The service or domain does not exist on this build.
    case unavailable
    /// Exists but could not be read by this process.
    case unreadable
}

public struct SettingStatus: Codable, Equatable, Sendable {
    public let setting: ControlSetting
    public let availability: SettingAvailability
    public let current: SettingValue?
    public let desired: SettingValue
    public let matchesDesired: Bool?
    public let detail: String?
}

public enum ControlState: String, Codable, Sendable {
    /// Every available setting is in the debloated state.
    case debloated
    /// No setting is in the debloated state (macOS default or the user's own choice).
    case stock
    /// Some settings are debloated and some are not.
    case partial
    /// MACSPACE applied the control, but a setting has since returned to another value (e.g. after an OS update).
    case drifted
    /// MACSPACE generated a configuration profile for it that the user has not approved (or has since removed).
    case awaitingApproval
    /// None of the control's settings exist on this build.
    case unavailable
    case unknown
}

public enum EffectState: String, Codable, Sendable {
    case effective
    /// The setting is applied but the unwanted behavior continues.
    case ineffective
    /// Applied, and the effect is expected after a restart.
    case pending
    /// The behavior cannot be switched off locally on this system (e.g. prerelease diagnostics).
    case notControllable
    case notMeasured
}

public struct EffectStatus: Codable, Equatable, Sendable {
    public let state: EffectState
    public let detail: String
}

public struct ControlStatus: Codable, Equatable, Sendable {
    public let controlID: String
    public let state: ControlState
    public let effect: EffectStatus?
    public let settings: [SettingStatus]
    public let validatedOnThisBuild: Bool
    /// When MACSPACE last applied the control and it has not been reverted since.
    public let appliedAt: Date?
}

// MARK: - Plans and results

public enum ChangeAction: String, Codable, Sendable {
    case apply
    case revert
}

public struct ChangeStep: Codable, Equatable, Sendable {
    public let setting: ControlSetting
    public let privilege: DebloatPrivilege
    public let from: SettingValue?
    public let to: SettingValue
    public let alreadySatisfied: Bool
    /// The command the step runs, for display.
    public let command: [String]
    /// Why this step cannot run, if it cannot.
    public let blocker: String?
    public let warning: String?
}

public struct ControlChangePlan: Codable, Equatable, Sendable {
    public let controlID: String
    public let action: ChangeAction
    public let steps: [ChangeStep]
    /// Reasons the whole plan cannot run.
    public let blockers: [String]
    public let warnings: [String]
    public let restart: RestartRequirement
    /// Services are stopped or loaded now rather than at the next restart.
    public let immediate: Bool

    public var runnable: Bool { blockers.isEmpty }
}

public enum StepOutcome: String, Codable, Sendable {
    case changed
    case alreadySatisfied
    /// Requires a different privilege than this process has.
    case skipped
    case blocked
    case failed
    /// A configuration profile was generated and opened; it takes effect once the user approves it.
    case pendingApproval
}

public struct StepResult: Codable, Equatable, Sendable {
    public let settingID: String
    public let outcome: StepOutcome
    public let detail: String?
}

public struct ControlChangeResult: Codable, Equatable, Sendable {
    public let plan: ControlChangePlan
    public let executed: Bool
    public let steps: [StepResult]
    public let statusAfter: ControlStatus?

    public init(plan: ControlChangePlan, executed: Bool, steps: [StepResult], statusAfter: ControlStatus?) {
        self.plan = plan
        self.executed = executed
        self.steps = steps
        self.statusAfter = statusAfter
    }
}

// MARK: - Journal

/// One setting change made by MACSPACE, recorded before the change is made so it can be undone.
public struct JournalEntry: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let at: Date
    public let controlID: String
    public let settingID: String
    public let setting: ControlSetting
    public let action: ChangeAction
    public let before: SettingValue
    public let after: SettingValue
    public let build: String?
    /// For apply entries: when a later revert undid this change.
    public var revertedAt: Date?

    public init(id: UUID = UUID(), at: Date, controlID: String, setting: ControlSetting, action: ChangeAction,
                before: SettingValue, after: SettingValue, build: String?, revertedAt: Date? = nil) {
        self.id = id
        self.at = at
        self.controlID = controlID
        self.settingID = setting.id
        self.setting = setting
        self.action = action
        self.before = before
        self.after = after
        self.build = build
        self.revertedAt = revertedAt
    }
}

public struct DebloatJournal: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var entries: [JournalEntry]

    public init(schemaVersion: Int = DebloatSchema.version, entries: [JournalEntry] = []) {
        self.schemaVersion = schemaVersion
        self.entries = entries
    }

    /// Apply entries not yet undone, oldest first.
    public var outstanding: [JournalEntry] {
        entries.filter { $0.action == .apply && $0.revertedAt == nil }.sorted { $0.at < $1.at }
    }
}
