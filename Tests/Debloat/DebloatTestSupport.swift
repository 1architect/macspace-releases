import Foundation
import MacSpacePlatform
@testable import MacSpaceDebloatPrivileged
import MacSpacePlatform

/// In-memory Mac: preferences, launchd overrides, processes and diagnostics history.
final class FakeDebloatSystem: DebloatSystem {
    var clock = Date(timeIntervalSince1970: 1_800_000_000)
    var env = DebloatEnvironment(productVersion: "27.2", build: "26B5091g", isPrerelease: true, sip: .enabled,
                                 mdmEnrolled: false, depEnrolled: false, architecture: "arm64", userName: "tester",
                                 uid: 501, runningAsRoot: false, fullDiskAccess: true)
    var preferences: [String: PlistValue] = [:]
    var overrides: [String: Bool] = [:]
    var unreadable: Set<String> = []
    var failingWrites: Set<String> = []
    var ignoredWrites: Set<String> = []
    var jobs: [LaunchdJob] = []
    var runningProcesses: [RunningProcess]? = []
    var history: DiagnosticSubmissionHistory?
    var writes: [(String, SettingValue)] = []
    var sessionCalls: [String] = []
    /// Values forced by an installed profile, by setting id.
    var forced: [String: PlistValue] = [:]
    var liveFlags: [String: Bool] = [:]
    var stagedProfiles: [Data] = []
    var failStaging = false
    /// RemovableServices of the rootless policy; nil disables the SIP rule.
    var removable: Set<String>?
    var failSessionCalls = false

    /// Registers a launchd job for every service in the catalog so services read as available.
    init(controls: [DebloatControl] = DebloatCatalog.controls) {
        for control in controls {
            for setting in control.settings {
                guard let service = setting.launchd else { continue }
                jobs.append(LaunchdJob(label: service.label, domain: service.domain, program: "/fake/\(service.label)",
                                       plistPath: "/System/Library/\(service.domain == .system ? "LaunchDaemons" : "LaunchAgents")/\(service.label).plist",
                                       disabledByDefault: nil, conditionallyDisabled: false))
            }
        }
    }

    func now() -> Date { clock }
    func environment() -> DebloatEnvironment { env }
    func launchdJobs() -> LaunchdJobIndex { LaunchdJobIndex(jobs: jobs) }

    func read(_ setting: ControlSetting) -> SettingRead {
        if unreadable.contains(setting.id) { return .unreadable("unreadable in test") }
        switch setting.kind {
        case .preference, .featureFlag, .systemTool:
            return .value(preferences[setting.id].map { .value($0) } ?? .absent)
        case .managedPreference:
            return .value(forced[setting.id].map { .value($0) } ?? .absent)
        case .launchdService:
            let service = setting.launchd!
            guard launchdJobs().job(service.domain, service.label) != nil else { return .unavailable("missing in test") }
            return .value(overrides[setting.id].map { .launchdOverride(disabled: $0) } ?? .absent)
        }
    }

    func write(_ setting: ControlSetting, value: SettingValue) throws {
        if failingWrites.contains(setting.id) { throw DebloatSystemError.commandFailed("write failed in test") }
        if setting.kind == .managedPreference { throw DebloatSystemError.unsupportedValue(setting: setting.id, value: value) }
        writes.append((setting.id, value))
        if ignoredWrites.contains(setting.id) { return }
        switch value {
        case .absent: preferences[setting.id] = nil
        case .value(let plist): preferences[setting.id] = plist
        case .launchdOverride(let disabled): overrides[setting.id] = disabled
        }
    }

    func command(for setting: ControlSetting, value: SettingValue) -> [String] { ["fake", setting.id, value.description] }
    var loadedServices: Set<String>?
    func stopService(_ service: LaunchdServiceSetting) throws -> Bool {
        if failSessionCalls { throw DebloatSystemError.blockedBySIP }
        sessionCalls.append("stop \(service.label)")
        runningProcesses?.removeAll { $0.executable == "/fake/\(service.label)" }
        return loadedServices?.remove(service.label) != nil || loadedServices == nil
    }
    func liveFeatureFlag(domain: String, feature: String) -> Bool? { liveFlags["\(domain)/\(feature)"] }
    func sipRemovableServices() -> Set<String>? { removable }
    var forceEnabled: Set<String> = []
    func launchdForceEnabled(_ service: LaunchdServiceSetting) -> Bool { forceEnabled.contains(service.label) }
    var decisions: [SubmissionDecision]? = []
    /// As `log show --start` does on the Mac: everything, whatever the start.
    var decisionsIgnoreStart = false
    func submissionDecisions(since: Date) -> [SubmissionDecision]? { decisionsIgnoreStart ? decisions : decisions?.filter { $0.at >= since } }
    func stageProfile(_ profile: Data, fileName: String) throws -> String {
        if failStaging { throw DebloatSystemError.commandFailed("open failed in test") }
        stagedProfiles.append(profile)
        stagedFileNames.append(fileName)
        return "staged in test"
    }
    var stagedFileNames: [String] = []
    /// As root (the helper) profiles can be removed; as the user they cannot.
    var removesProfiles = false
    var removedProfiles: [String] = []
    func removeProfile(identifier: String) throws -> String {
        guard removesProfiles else { throw DebloatSystemError.commandFailed("needs root in test") }
        removedProfiles.append(identifier)
        return "removed \(identifier)"
    }
    /// The managed values in the last staged profile, as payloadType:key -> value.
    var lastProfileValues: [String: PlistValue] {
        guard let data = stagedProfiles.last,
              let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let payloads = root["PayloadContent"] as? [[String: Any]] else { return [:] }
        var values: [String: PlistValue] = [:]
        for payload in payloads {
            let type = payload["PayloadType"] as! String
            for (key, value) in payload where !key.hasPrefix("Payload") { values["\(type):\(key)"] = PlistValue(propertyList: value) }
        }
        return values
    }
    func startService(_ service: LaunchdServiceSetting) throws -> Bool {
        if failSessionCalls { throw DebloatSystemError.blockedBySIP }
        sessionCalls.append("start \(service.label)")
        return loadedServices?.insert(service.label).inserted ?? true
    }
    func processes() -> [RunningProcess]? { runningProcesses }
    func diagnosticHistory() -> DiagnosticSubmissionHistory? { history }
}

final class MemoryJournalStore: DebloatJournalStoring {
    var journals: [DebloatPrivilege: DebloatJournal] = [:]
    var failSaves = false

    func load(_ privilege: DebloatPrivilege) -> DebloatJournal { journals[privilege] ?? DebloatJournal() }
    func save(_ journal: DebloatJournal, _ privilege: DebloatPrivilege) throws {
        if failSaves { throw DebloatSystemError.commandFailed("journal save failed in test") }
        journals[privilege] = journal
    }
}

func process(_ executable: String, pid: Int32 = 100, rssKiB: UInt64 = 1024, elapsed: Int? = 60) -> RunningProcess {
    RunningProcess(pid: pid, ppid: 1, uid: 501, residentBytes: rssKiB * 1024, elapsedSeconds: elapsed, executable: executable)
}
