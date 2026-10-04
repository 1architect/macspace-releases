import Foundation
import MacSpacePlatform
#if canImport(Darwin)
import Darwin
#endif

public enum SettingRead: Equatable, Sendable {
    case value(SettingValue)
    /// The service or domain does not exist on this build.
    case unavailable(String)
    case unreadable(String)
}

public enum DebloatSystemError: Error, Equatable, CustomStringConvertible {
    case unsupportedValue(setting: String, value: SettingValue)
    case commandFailed(String)
    case targetUserUnknown
    /// launchctl error 150: SIP refuses to stop or load Apple platform services at runtime.
    case blockedBySIP

    public var description: String {
        switch self {
        case .blockedBySIP: return "System Integrity Protection blocks stopping or loading Apple services now (launchctl error 150)"
        case let .unsupportedValue(setting, value): return "\(setting) cannot be set to \(value)."
        case .commandFailed(let message): return message
        case .targetUserUnknown: return "The logged-in user could not be determined."
        }
    }
}

/// Everything the debloat engine reads from or writes to the Mac, injectable for tests.
public protocol DebloatSystem: AnyObject {
    func now() -> Date
    func environment() -> DebloatEnvironment
    func launchdJobs() -> LaunchdJobIndex
    func read(_ setting: ControlSetting) -> SettingRead
    func write(_ setting: ControlSetting, value: SettingValue) throws
    /// The command `write` runs, for plans and logs.
    func command(for setting: ControlSetting, value: SettingValue) -> [String]
    /// Unloads a service from its launchd domain now (`launchctl bootout`). Returns false if it was not loaded.
    func stopService(_ service: LaunchdServiceSetting) throws -> Bool
    /// Loads a service into its launchd domain now (`launchctl bootstrap`). Returns false if it was already loaded.
    func startService(_ service: LaunchdServiceSetting) throws -> Bool
    /// The flag value libfeatureflags reports to processes now (computed at boot); nil if unreadable.
    func liveFeatureFlag(domain: String, feature: String) -> Bool?
    /// Writes the MacSpace configuration profile and opens it for approval; returns a description for the user.
    func stageProfile(_ profile: Data) throws -> String
    /// Removes the installed MacSpace profile (needs root); returns a description for the user.
    func removeProfile() throws -> String
    /// Labels whose launchd overrides survive with SIP enabled (`RemovableServices` in launchd's rootless
    /// policy); nil if the policy cannot be read.
    func sipRemovableServices() -> Set<String>?
    /// Whether launchd marks the loaded job `force-enabled`, in which case it ignores a disable override.
    func launchdForceEnabled(_ service: LaunchdServiceSetting) -> Bool
    func processes() -> [RunningProcess]?
    func diagnosticHistory() -> DiagnosticSubmissionHistory?
    /// SubmitDiagInfo's opt-in decisions logged since the given date; nil if the log cannot be read.
    func submissionDecisions(since: Date) -> [SubmissionDecision]?
}

public extension DebloatSystem {
    /// Systems that cannot remove the profile (test doubles) say so; the app then asks the helper.
    func removeProfile() throws -> String { throw DebloatSystemError.commandFailed("Removing the MacSpace profile needs root.") }
}

/// The user whose preferences and gui launchd domain are targeted: the current user, or `SUDO_USER` under sudo.
public struct DebloatTargetUser: Equatable, Sendable {
    public let name: String
    public let uid: UInt32
    public let home: URL

    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> DebloatTargetUser? {
        if geteuid() == 0 {
            guard let name = environment["SUDO_USER"], let uid = environment["SUDO_UID"].flatMap(UInt32.init),
                  let home = FileManager.default.homeDirectory(forUser: name) else { return nil }
            return DebloatTargetUser(name: name, uid: uid, home: home)
        }
        return DebloatTargetUser(name: NSUserName(), uid: getuid(), home: FileManager.default.homeDirectoryForCurrentUser)
    }
}

/// Live implementation. Preferences go through `defaults` (and therefore cfprefsd); launchd overrides go
/// through `launchctl`. Reads are cached per instance and invalidated by writes.
public final class LiveDebloatSystem: DebloatSystem {
    public static let defaultsPath = "/usr/bin/defaults"
    public static let launchctlPath = "/bin/launchctl"

    private let runner: any CommandRunning
    private let fileManager: FileManager
    private let targetUser: DebloatTargetUser?
    private let isRoot: Bool
    private var cachedJobs: LaunchdJobIndex?
    private var cachedOverrides: [LaunchdServiceSetting.Domain: [String: Bool]] = [:]
    private var cachedDomains: [String: [String: Any]] = [:]
    private var cachedEnvironment: DebloatEnvironment?
    private var cachedForceEnabled: [String: Bool] = [:]

    public init(runner: any CommandRunning = ProcessCommandRunner(defaultTimeout: 20), fileManager: FileManager = .default,
                targetUser: DebloatTargetUser? = DebloatTargetUser.resolve()) {
        self.runner = runner
        self.fileManager = fileManager
        self.targetUser = targetUser
        self.isRoot = geteuid() == 0
    }

    public func now() -> Date { Date() }

    private func output(_ executable: String, _ arguments: [String], timeout: TimeInterval? = nil) -> String? {
        guard let result = try? runner.run(executable, arguments, timeout: timeout), result.exitCode == 0 else { return nil }
        return String(decoding: result.stdout, as: UTF8.self)
    }

    // MARK: Environment

    public func environment() -> DebloatEnvironment {
        if let cachedEnvironment { return cachedEnvironment }
        let build = output("/usr/bin/sw_vers", ["-buildVersion"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        let enrollment = output("/usr/bin/profiles", ["status", "-type", "enrollment"]) ?? ""
        let seed = diagnosticHistory()?.seedAutoSubmit
        var machine = utsname()
        uname(&machine)
        let architecture = withUnsafeBytes(of: &machine.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let environment = DebloatEnvironment(
            productVersion: output("/usr/bin/sw_vers", ["-productVersion"])?.trimmingCharacters(in: .whitespacesAndNewlines),
            build: build,
            isPrerelease: Self.isPrerelease(build: build, seedAutoSubmit: seed),
            sip: Self.parseSIP(output("/usr/bin/csrutil", ["status"])),
            mdmEnrolled: Self.parseEnrollment(enrollment, prefix: "MDM enrollment:"),
            depEnrolled: Self.parseEnrollment(enrollment, prefix: "Enrolled via DEP:"),
            architecture: architecture.isEmpty ? nil : architecture,
            userName: targetUser?.name ?? NSUserName(),
            uid: targetUser?.uid ?? getuid(),
            runningAsRoot: isRoot,
            fullDiskAccess: Self.probeFullDiskAccess(home: targetUser?.home, fileManager: fileManager),
            bootedAt: Self.bootTime(),
            sessionStartedAt: targetUser.flatMap { user in
                processes()?.filter { $0.executable == Self.loginwindowPath && $0.uid == user.uid }
                    .compactMap { $0.startedAt(now: now()) }.min()
            }
        )
        cachedEnvironment = environment
        return environment
    }

    /// Files that only a process with Full Disk Access can open. The user's TCC.db alone is not enough: on 26B5091g it
    /// stayed unreadable with Full Disk Access granted, while os_eligibility became readable.
    public static func fullDiskAccessProbes(home: URL?) -> [String] {
        ["/private/var/db/os_eligibility/eligibility.plist"]
            + (home.map { [$0.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db").path] } ?? [])
    }

    /// true if any existing probe opens; false if probes exist and none opens; nil if no probe exists.
    public static func probeFullDiskAccess(home: URL?, fileManager: FileManager = .default) -> Bool? {
        let existing = fullDiskAccessProbes(home: home).filter { fileManager.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return nil }
        return existing.contains { path in
            guard let handle = FileHandle(forReadingAtPath: path) else { return false }
            try? handle.close()
            return true
        }
    }

    public static let loginwindowPath = "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow"

    public static func bootTime() -> Date? {
        var value = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &value, &size, nil, 0) == 0, value.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000)
    }

    /// Beta builds carry a four-digit build number and a lowercase suffix (26B5091g); Rapid Security Response
    /// builds also end in a lowercase letter but have longer numbers (22E772610a).
    public static func isPrerelease(build: String?, seedAutoSubmit: Bool?) -> Bool? {
        if seedAutoSubmit == true { return true }
        guard let build else { return nil }
        return build.range(of: #"^[0-9]+[A-Z][0-9]{4}[a-z]$"#, options: .regularExpression) != nil
    }

    public static func parseSIP(_ text: String?) -> SIPState {
        guard let text = text?.lowercased() else { return .unknown }
        if text.contains("custom configuration") { return .custom }
        if text.contains("status: enabled") { return .enabled }
        if text.contains("status: disabled") { return .disabled }
        return .unknown
    }

    public static func parseEnrollment(_ text: String, prefix: String) -> Bool? {
        guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix(prefix) }) else { return nil }
        return line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("yes")
    }

    // MARK: Settings

    public func launchdJobs() -> LaunchdJobIndex {
        if let cachedJobs { return cachedJobs }
        let jobs = LaunchdJobIndex.load(fileManager: fileManager)
        cachedJobs = jobs
        return jobs
    }

    private func launchdTarget(_ domain: LaunchdServiceSetting.Domain) -> String? {
        switch domain {
        case .system: return "system"
        case .gui: return targetUser.map { "gui/\($0.uid)" }
        }
    }

    private func overrides(_ domain: LaunchdServiceSetting.Domain) -> [String: Bool]? {
        if let cached = cachedOverrides[domain] { return cached }
        guard let target = launchdTarget(domain), let text = output(Self.launchctlPath, ["print-disabled", target]) else { return nil }
        let parsed = LaunchdOverrideParser.parse(text)
        cachedOverrides[domain] = parsed
        return parsed
    }

    private func defaultsPrefix(_ preference: PreferenceSetting) -> [String] {
        preference.scope == .currentHost ? ["-currentHost"] : []
    }

    private func domainContents(_ preference: PreferenceSetting) -> [String: Any]? {
        let cacheKey = "\(preference.scope.rawValue):\(preference.domain)"
        if let cached = cachedDomains[cacheKey] { return cached }
        guard let result = try? runner.run(Self.defaultsPath, defaultsPrefix(preference) + ["export", preference.domain, "-"], timeout: 10),
              result.exitCode == 0,
              let root = try? PropertyListSerialization.propertyList(from: result.stdout, options: [], format: nil) as? [String: Any]
        else { return nil }
        cachedDomains[cacheKey] = root
        return root
    }

    public func read(_ setting: ControlSetting) -> SettingRead {
        switch setting.kind {
        case .preference:
            let preference = setting.preference!
            if isRoot, preference.scope != .systemFile {
                return .unreadable("User preference; run without sudo to read it.")
            }
            guard let contents = domainContents(preference) else { return .unreadable("`defaults export \(preference.domain)` failed.") }
            guard let object = contents[preference.key] else { return .value(.absent) }
            guard let value = PlistValue(propertyList: object) else { return .unreadable("Unsupported value type for \(preference.key).") }
            return .value(.value(value))
        case .featureFlag:
            let flag = setting.featureFlag!
            guard Self.systemFeatureExists(domain: flag.domain, feature: flag.feature, fileManager: fileManager) else {
                return .unavailable("No feature flag \(flag.domain)/\(flag.feature) on this build.")
            }
            guard let data = fileManager.contents(atPath: flag.overridePath) else {
                return fileManager.fileExists(atPath: flag.overridePath) ? .unreadable("\(flag.overridePath) is not readable.") : .value(.absent)
            }
            guard let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
                return .unreadable("\(flag.overridePath) is not a property list.")
            }
            let enabled = ((root[flag.feature] as? [String: Any])?["Enabled"] as? NSNumber)?.boolValue
            return .value(enabled.map { .value(.bool($0)) } ?? .absent)
        case .systemTool:
            switch setting.tool!.tool {
            case .tailspin:
                guard let text = output("/usr/bin/tailspin", ["info"], timeout: 10) else { return .unreadable("`tailspin info` failed.") }
                guard let enabled = Self.parseTailspinEnabled(text) else { return .unreadable("Unrecognized `tailspin info` output.") }
                return .value(.value(.bool(enabled)))
            case .spotlightIndexing:
                guard let text = output("/usr/bin/mdutil", ["-s", "/"], timeout: 15) else { return .unreadable("`mdutil -s /` failed.") }
                guard let enabled = Self.parseMdutilIndexing(text) else { return .unreadable("Unrecognized `mdutil -s /` output.") }
                return .value(.value(.bool(enabled)))
            }
        case .managedPreference:
            let managed = setting.managed!
            let domain = managed.payloadType as CFString
            CFPreferencesAppSynchronize(domain)
            guard CFPreferencesAppValueIsForced(managed.key as CFString, domain),
                  let object = CFPreferencesCopyAppValue(managed.key as CFString, domain) else { return .value(.absent) }
            guard let value = PlistValue(propertyList: object) else { return .unreadable("Unsupported managed value for \(managed.key).") }
            return .value(.value(value))
        case .launchdService:
            let service = setting.launchd!
            guard launchdJobs().job(service.domain, service.label) != nil else {
                return .unavailable("No \(service.domain == .system ? "LaunchDaemon" : "LaunchAgent") named \(service.label) on this build.")
            }
            guard let overrides = overrides(service.domain) else {
                return .unreadable("`launchctl print-disabled \(launchdTarget(service.domain) ?? service.domain.rawValue)` failed.")
            }
            return .value(overrides[service.label].map { .launchdOverride(disabled: $0) } ?? .absent)
        }
    }

    public func command(for setting: ControlSetting, value: SettingValue) -> [String] {
        switch (setting.kind, value) {
        case (.preference, .value(let plist)):
            let p = setting.preference!
            return [Self.defaultsPath] + defaultsPrefix(p) + ["write", p.domain, p.key] + plist.defaultsWriteArguments
        case (.preference, .absent):
            let p = setting.preference!
            return [Self.defaultsPath] + defaultsPrefix(p) + ["delete", p.domain, p.key]
        case (.launchdService, .launchdOverride(let disabled)):
            let service = setting.launchd!
            let target = launchdTarget(service.domain) ?? "gui/<uid>"
            return [Self.launchctlPath, disabled ? "disable" : "enable", "\(target)/\(service.label)"]
        // Feature-flag overrides are written with Foundation; this PlistBuddy sequence is the equivalent for the
        // file as it is now.
        case (.featureFlag, .value(.bool(let enabled))):
            let flag = setting.featureFlag!
            let entry = (fileManager.contents(atPath: flag.overridePath)
                .flatMap { try? PropertyListSerialization.propertyList(from: $0, options: [], format: nil) } as? [String: Any])?[flag.feature] as? [String: Any]
            var commands: [String] = []
            if entry == nil { commands.append("Add :\(flag.feature) dict") }
            if entry?["DevelopmentPhase"] != nil { commands.append("Delete :\(flag.feature):DevelopmentPhase") }
            commands.append(entry?["Enabled"] == nil ? "Add :\(flag.feature):Enabled bool \(enabled)" : "Set :\(flag.feature):Enabled \(enabled)")
            return ["/usr/libexec/PlistBuddy"] + commands.flatMap { ["-c", $0] } + [flag.overridePath]
        case (.featureFlag, .absent):
            let flag = setting.featureFlag!
            return ["/usr/libexec/PlistBuddy", "-c", "Delete :\(flag.feature):Enabled", flag.overridePath]
        case (.managedPreference, _):
            return ["/usr/bin/open", profileURL?.path ?? ConfigurationProfileBuilder.fileName]
        case (.systemTool, .value(.bool(let enabled))):
            switch setting.tool!.tool {
            case .tailspin: return ["/usr/bin/tailspin", enabled ? "enable" : "disable"]
            case .spotlightIndexing: return ["/usr/bin/mdutil", "-a", "-i", enabled ? "on" : "off"]
            }
        default:
            return []
        }
    }

    public static let rootlessPolicyPath = "/System/Library/Sandbox/com.apple.xpc.launchd.rootless.plist"

    public func launchdForceEnabled(_ service: LaunchdServiceSetting) -> Bool {
        let key = "\(service.domain.rawValue)/\(service.label)"
        if let cached = cachedForceEnabled[key] { return cached }
        guard let target = launchdTarget(service.domain) else { return false }
        let forced = output(Self.launchctlPath, ["print", "\(target)/\(service.label)"], timeout: 10).map(Self.parseForceEnabled) ?? false
        cachedForceEnabled[key] = forced
        return forced
    }

    /// Reads the `properties = …` line of `launchctl print <service>`.
    public static func parseForceEnabled(_ text: String) -> Bool {
        text.split(separator: "\n").first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("properties =") }?
            .split(separator: "|").contains { $0.trimmingCharacters(in: .whitespaces).hasSuffix("force-enabled") } ?? false
    }

    public func sipRemovableServices() -> Set<String>? {
        fileManager.contents(atPath: Self.rootlessPolicyPath).flatMap(Self.parseRemovableServices)
    }

    public static func parseRemovableServices(_ data: Data) -> Set<String>? {
        guard let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let services = root["RemovableServices"] as? [String: Any] else { return nil }
        return Set(services.filter { ($0.value as? NSNumber)?.boolValue ?? true }.keys)
    }

    /// `tailspin info` starts with "tailspin has been enabled…" or "…disabled…" (after a blank line).
    public static func parseTailspinEnabled(_ text: String) -> Bool? {
        guard let line = text.split(separator: "\n").first(where: { $0.contains("tailspin has been") }) else { return nil }
        if line.contains("has been disabled") { return false }
        if line.contains("has been enabled") { return true }
        return nil
    }

    /// `mdutil -s /` reports "Indexing enabled." or "Indexing disabled."
    public static func parseMdutilIndexing(_ text: String) -> Bool? {
        if text.contains("Indexing disabled") { return false }
        if text.contains("Indexing enabled") { return true }
        return nil
    }

    public static let featureFlagDirectories = ["/System/Library/FeatureFlags/Domain", "/System/Library/FeatureFlags/Unified/Domain"]

    public static func systemFeatureExists(domain: String, feature: String, fileManager: FileManager = .default) -> Bool {
        featureFlagDirectories.contains { directory in
            guard let data = fileManager.contents(atPath: "\(directory)/\(domain).plist"),
                  let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
            else { return false }
            return root[feature] != nil
        }
    }

    /// Sets or removes `Enabled` for one feature, keeping every other entry in the override file. An override file
    /// left empty is deleted.
    public static func updateFeatureFlagOverride(_ flag: FeatureFlagSetting, enabled: Bool?, fileManager: FileManager = .default,
                                                 path: String? = nil) throws {
        let path = path ?? flag.overridePath
        var root: [String: Any] = [:]
        if let data = fileManager.contents(atPath: path) {
            guard let existing = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
                throw DebloatSystemError.commandFailed("\(path) is not a dictionary property list.")
            }
            root = existing
        }
        var entry = root[flag.feature] as? [String: Any] ?? [:]
        if let enabled {
            entry["Enabled"] = enabled
            entry.removeValue(forKey: "DevelopmentPhase") // libfeatureflags rejects a flag with both keys
        } else {
            entry.removeValue(forKey: "Enabled")
        }
        root[flag.feature] = entry.isEmpty ? nil : entry

        let url = URL(fileURLWithPath: path)
        if root.isEmpty {
            if fileManager.fileExists(atPath: path) { try fileManager.removeItem(at: url) }
            return
        }
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o755])
        try PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0).write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
    }

    private var profileURL: URL? {
        targetUser?.home.appendingPathComponent("Library/Application Support/MacSpace/Profiles/\(ConfigurationProfileBuilder.fileName)")
    }

    public func removeProfile() throws -> String {
        guard isRoot else { throw DebloatSystemError.commandFailed("Removing the MacSpace profile needs root.") }
        let result = try runner.run("/usr/bin/profiles", ["remove", "-identifier", ConfigurationProfileBuilder.identifier], timeout: 30)
        guard result.exitCode == 0 else {
            let message = String(decoding: result.stderr + result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw DebloatSystemError.commandFailed("profiles remove failed: \(message)")
        }
        return "Removed the \"\(ConfigurationProfileBuilder.displayName)\" profile; the policies no longer apply."
    }

    public func stageProfile(_ profile: Data) throws -> String {
        guard let url = profileURL else { throw DebloatSystemError.targetUserUnknown }
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try profile.write(to: url, options: .atomic)
        do { _ = try runner.run("/usr/bin/open", [url.path], timeout: 15) }
        catch { throw DebloatSystemError.commandFailed("Wrote \(url.path) but could not open it: \(error)") }
        return "Opened \(url.path); approve \"\(ConfigurationProfileBuilder.displayName)\" in System Settings > General > Device Management."
    }

    public func liveFeatureFlag(domain: String, feature: String) -> Bool? {
        // RTLD_DEFAULT is (void *)-2 on Darwin.
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_os_feature_enabled_impl") else { return nil }
        typealias FeatureEnabled = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> Bool
        let isEnabled = unsafeBitCast(symbol, to: FeatureEnabled.self)
        return domain.withCString { d in feature.withCString { f in isEnabled(d, f) } }
    }

    public func write(_ setting: ControlSetting, value: SettingValue) throws {
        switch (setting.kind, value) {
        case (.featureFlag, .value(.bool(let enabled))):
            try Self.updateFeatureFlagOverride(setting.featureFlag!, enabled: enabled, fileManager: fileManager)
            return
        case (.featureFlag, .absent):
            try Self.updateFeatureFlagOverride(setting.featureFlag!, enabled: nil, fileManager: fileManager)
            return
        case (.featureFlag, _), (.managedPreference, _):
            // Managed preferences change only through an approved profile (see stageProfile).
            throw DebloatSystemError.unsupportedValue(setting: setting.id, value: value)
        default:
            break
        }
        let arguments = command(for: setting, value: value)
        guard let executable = arguments.first else { throw DebloatSystemError.unsupportedValue(setting: setting.id, value: value) }
        if setting.kind == .launchdService, launchdTarget(setting.launchd!.domain) == nil { throw DebloatSystemError.targetUserUnknown }
        defer {
            cachedDomains.removeAll()
            cachedOverrides.removeAll()
        }
        do {
            _ = try runner.run(executable, Array(arguments.dropFirst()), timeout: 15)
        } catch CommandRunnerError.nonZeroExit(_, _, _, let stderr) where value == .absent && stderr.contains("does not exist") {
            return
        } catch {
            throw DebloatSystemError.commandFailed((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    public static let sipBlockedExitCode: Int32 = 150

    /// Runs launchctl; returns false when it exits with one of the `unchanged` codes.
    private func launchctl(_ arguments: [String], unchanged codes: Set<Int32>) throws -> Bool {
        defer { cachedOverrides.removeAll() }
        do {
            _ = try runner.run(Self.launchctlPath, arguments, timeout: 15)
            return true
        } catch CommandRunnerError.nonZeroExit(_, _, let code, _) where codes.contains(code) {
            return false
        } catch CommandRunnerError.nonZeroExit(_, _, Self.sipBlockedExitCode, _) {
            throw DebloatSystemError.blockedBySIP
        } catch {
            throw DebloatSystemError.commandFailed((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    public func stopService(_ service: LaunchdServiceSetting) throws -> Bool {
        guard let target = launchdTarget(service.domain) else { throw DebloatSystemError.targetUserUnknown }
        // 3 (ESRCH) and 113 ("Could not find specified service") mean it is not loaded.
        return try launchctl(["bootout", "\(target)/\(service.label)"], unchanged: [3, 113])
    }

    public func startService(_ service: LaunchdServiceSetting) throws -> Bool {
        guard let target = launchdTarget(service.domain) else { throw DebloatSystemError.targetUserUnknown }
        guard let plist = launchdJobs().job(service.domain, service.label)?.plistPath else {
            throw DebloatSystemError.commandFailed("No plist for \(service.label) on this build.")
        }
        // 5 and 37 are returned when the service is already loaded.
        return try launchctl(["bootstrap", target, plist], unchanged: [5, 37])
    }

    // MARK: Observations

    public func processes() -> [RunningProcess]? {
        output("/bin/ps", ["-axo", "pid=,ppid=,uid=,rss=,etime=,comm="]).map(ProcessListParser.parse)
    }

    public func diagnosticHistory() -> DiagnosticSubmissionHistory? {
        fileManager.contents(atPath: DiagnosticSubmissionHistory.path).flatMap(DiagnosticSubmissionHistory.parse)
    }

    public func submissionDecisions(since: Date) -> [SubmissionDecision]? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return output("/usr/bin/log", ["show", "--start", formatter.string(from: since), "--style", "ndjson", "--predicate",
                                       "process == \"SubmitDiagInfo\" AND eventMessage BEGINSWITH \"Initiating submission for\""],
                      timeout: 60).map(SubmissionDecisionParser.parse)
    }
}
