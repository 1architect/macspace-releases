import Foundation

// MARK: - Processes

public struct RunningProcess: Codable, Equatable, Sendable {
    public let pid: Int32
    public let ppid: Int32
    public let uid: UInt32
    public let residentBytes: UInt64
    public let elapsedSeconds: Int?
    public let executable: String

    public init(pid: Int32, ppid: Int32, uid: UInt32, residentBytes: UInt64, elapsedSeconds: Int?, executable: String) {
        self.pid = pid
        self.ppid = ppid
        self.uid = uid
        self.residentBytes = residentBytes
        self.elapsedSeconds = elapsedSeconds
        self.executable = executable
    }

    public func startedAt(now: Date) -> Date? { elapsedSeconds.map { now.addingTimeInterval(-Double($0)) } }
    public var name: String { (executable as NSString).lastPathComponent }
}

public enum ProcessListParser {
    /// Parses `ps -axo pid=,ppid=,uid=,rss=,etime=,comm=`; `comm` is the full executable path on macOS and may contain spaces.
    public static func parse(_ text: String) -> [RunningProcess] {
        text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            guard fields.count == 6, let pid = Int32(fields[0]), let ppid = Int32(fields[1]), let uid = UInt32(fields[2]),
                  let rssKiB = UInt64(fields[3]) else { return nil }
            return RunningProcess(pid: pid, ppid: ppid, uid: uid, residentBytes: rssKiB * 1024,
                                  elapsedSeconds: elapsedSeconds(String(fields[4])),
                                  executable: String(fields[5]).trimmingCharacters(in: .whitespaces))
        }
    }

    /// Parses `ps` elapsed time `[[dd-]hh:]mm:ss`.
    public static func elapsedSeconds(_ text: String) -> Int? {
        var days = 0
        var clock = Substring(text)
        if let dash = text.firstIndex(of: "-") {
            guard let value = Int(text[..<dash]) else { return nil }
            days = value
            clock = text[text.index(after: dash)...]
        }
        let parts = clock.split(separator: ":").map { Int($0) }
        guard (2...3).contains(parts.count), !parts.contains(nil) else { return nil }
        let numbers = parts.map { $0! }
        let seconds = numbers.count == 3 ? numbers[0] * 3600 + numbers[1] * 60 + numbers[2] : numbers[0] * 60 + numbers[1]
        return days * 86400 + seconds
    }
}

// MARK: - launchd

public struct LaunchdJob: Codable, Equatable, Sendable {
    public let label: String
    public let domain: LaunchdServiceSetting.Domain
    public let program: String?
    public let plistPath: String
    /// The plist's own `Disabled` key: true/false, or nil when absent or conditional on a feature flag.
    public let disabledByDefault: Bool?
    public let conditionallyDisabled: Bool

    public init(label: String, domain: LaunchdServiceSetting.Domain, program: String?, plistPath: String,
                disabledByDefault: Bool?, conditionallyDisabled: Bool) {
        self.label = label
        self.domain = domain
        self.program = program
        self.plistPath = plistPath
        self.disabledByDefault = disabledByDefault
        self.conditionallyDisabled = conditionallyDisabled
    }
}

/// launchd job definitions shipped with the OS, indexed by label and by program path.
public struct LaunchdJobIndex: Sendable {
    public static let directories: [(String, LaunchdServiceSetting.Domain)] = [
        ("/System/Library/LaunchDaemons", .system),
        ("/System/Library/LaunchAgents", .gui),
        ("/Library/LaunchDaemons", .system),
        ("/Library/LaunchAgents", .gui),
    ]

    public let jobs: [LaunchdJob]
    private let byKey: [String: LaunchdJob]
    private let byProgram: [String: [LaunchdJob]]

    public init(jobs: [LaunchdJob]) {
        self.jobs = jobs
        var byKey: [String: LaunchdJob] = [:]
        var byProgram: [String: [LaunchdJob]] = [:]
        for job in jobs {
            byKey["\(job.domain.rawValue):\(job.label)"] = byKey["\(job.domain.rawValue):\(job.label)"] ?? job
            if let program = job.program { byProgram[program, default: []].append(job) }
        }
        self.byKey = byKey
        self.byProgram = byProgram
    }

    public func job(_ domain: LaunchdServiceSetting.Domain, _ label: String) -> LaunchdJob? { byKey["\(domain.rawValue):\(label)"] }
    public func jobs(forProgram program: String) -> [LaunchdJob] { byProgram[program] ?? [] }

    public static func parse(plist data: Data, path: String, domain: LaunchdServiceSetting.Domain) -> LaunchdJob? {
        guard let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let label = root["Label"] as? String else { return nil }
        let program = (root["Program"] as? String) ?? (root["ProgramArguments"] as? [String])?.first
        let disabled = root["Disabled"]
        return LaunchdJob(label: label, domain: domain, program: program, plistPath: path,
                          disabledByDefault: (disabled as? NSNumber)?.boolValue,
                          conditionallyDisabled: disabled is [String: Any])
    }

    public static func load(fileManager: FileManager = .default) -> LaunchdJobIndex {
        var jobs: [LaunchdJob] = []
        for (directory, domain) in directories {
            guard let names = try? fileManager.contentsOfDirectory(atPath: directory) else { continue }
            for name in names.sorted() where name.hasSuffix(".plist") {
                let path = "\(directory)/\(name)"
                if let data = fileManager.contents(atPath: path), let job = parse(plist: data, path: path, domain: domain) {
                    jobs.append(job)
                }
            }
        }
        return LaunchdJobIndex(jobs: jobs)
    }
}

public enum LaunchdOverrideParser {
    /// Parses `launchctl print-disabled <domain>` into label -> disabled. Accepts both `disabled`/`enabled`
    /// and the older `true`/`false` spellings.
    public static func parse(_ text: String) -> [String: Bool] {
        var result: [String: Bool] = [:]
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\""), let arrow = trimmed.range(of: "\" => ") else { continue }
            let label = String(trimmed[trimmed.index(after: trimmed.startIndex)..<arrow.lowerBound])
            switch trimmed[arrow.upperBound...].trimmingCharacters(in: .whitespaces) {
            case "disabled", "true": result[label] = true
            case "enabled", "false": result[label] = false
            default: continue
            }
        }
        return result
    }
}

// MARK: - Diagnostics submission

public struct DiagnosticSubmissionHistory: Codable, Equatable, Sendable {
    public static let path = "/Library/Application Support/CrashReporter/DiagnosticMessagesHistory.plist"

    public let autoSubmit: Bool?
    public let thirdPartyDataSubmit: Bool?
    public let seedAutoSubmit: Bool?
    public let lastFullSubmissionCalled: Date?
    public let lastFullSubmissionSuccess: Date?

    public init(autoSubmit: Bool?, thirdPartyDataSubmit: Bool?, seedAutoSubmit: Bool?,
                lastFullSubmissionCalled: Date?, lastFullSubmissionSuccess: Date?) {
        self.autoSubmit = autoSubmit
        self.thirdPartyDataSubmit = thirdPartyDataSubmit
        self.seedAutoSubmit = seedAutoSubmit
        self.lastFullSubmissionCalled = lastFullSubmissionCalled
        self.lastFullSubmissionSuccess = lastFullSubmissionSuccess
    }

    public static func parse(_ data: Data) -> DiagnosticSubmissionHistory? {
        guard let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else { return nil }
        func bool(_ key: String) -> Bool? { (root[key] as? NSNumber)?.boolValue }
        return DiagnosticSubmissionHistory(autoSubmit: bool("AutoSubmit"), thirdPartyDataSubmit: bool("ThirdPartyDataSubmit"),
                                           seedAutoSubmit: bool("SeedAutoSubmit"),
                                           lastFullSubmissionCalled: root["LastFullSubmissionCalled"] as? Date,
                                           lastFullSubmissionSuccess: root["LastFullSubmissionSuccess"] as? Date)
    }
}

/// One SubmitDiagInfo decision from the unified log ("Initiating submission for 'Primary' optIn: IN|OUT").
public struct SubmissionDecision: Codable, Equatable, Sendable {
    public let at: Date
    public let optedIn: Bool

    public init(at: Date, optedIn: Bool) {
        self.at = at
        self.optedIn = optedIn
    }
}

public enum SubmissionDecisionParser {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"
        return formatter
    }()

    /// Parses `log show --style ndjson` output.
    public static func parse(_ text: String) -> [SubmissionDecision] {
        text.split(separator: "\n").compactMap { line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let message = object["eventMessage"] as? String, message.hasPrefix("Initiating submission for"),
                  let timestamp = object["timestamp"] as? String, let date = formatter.date(from: timestamp) else { return nil }
            if message.hasSuffix("optIn: IN") { return SubmissionDecision(at: date, optedIn: true) }
            if message.hasSuffix("optIn: OUT") { return SubmissionDecision(at: date, optedIn: false) }
            return nil
        }
    }
}
