import Foundation
import MacSpacePlatform
@preconcurrency import UserNotifications

/// Notify-only watcher for the Apple Intelligence language guard. It never re-applies the
/// workaround; it records state transitions and tells the user when protection is lost.

public struct AppleIntelligenceWatchRecord: Codable, Sendable, Equatable {
    public let state: AppleIntelligenceGuardState
    /// When the current state was first observed.
    public let since: Date
    public let lastChecked: Date
    /// Whether the user has already been alerted about this state (including a lingering release).
    public let alerted: Bool
    /// A warning reached the user since protection was last in place: only then is its return announced.
    public let warned: Bool

    public init(state: AppleIntelligenceGuardState, since: Date, lastChecked: Date, alerted: Bool, warned: Bool = false) {
        self.state = state
        self.since = since
        self.lastChecked = lastChecked
        self.alerted = alerted
        self.warned = warned
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = try container.decode(AppleIntelligenceGuardState.self, forKey: .state)
        since = try container.decode(Date.self, forKey: .since)
        lastChecked = try container.decode(Date.self, forKey: .lastChecked)
        alerted = try container.decode(Bool.self, forKey: .alerted)
        warned = try container.decodeIfPresent(Bool.self, forKey: .warned) ?? false
    }
}

public struct AppleIntelligenceWatchAlert: Codable, Sendable, Equatable {
    public enum Severity: String, Codable, Sendable { case warning, info }
    public let severity: Severity
    public let title: String
    public let message: String
}

public struct AppleIntelligenceWatchOutcome: Codable, Sendable, Equatable {
    public let previous: AppleIntelligenceWatchRecord?
    public let record: AppleIntelligenceWatchRecord
    public let transitioned: Bool
    public let alert: AppleIntelligenceWatchAlert?
}

public struct AppleIntelligenceWatcher: Sendable {
    /// A release (ineligible, model still present) that lasts longer than this is reported as stuck.
    public static let defaultReleaseGrace: TimeInterval = 60 * 60
    /// State that cannot be read is reported only once it has stayed unreadable this long: a copy of MacSpace without Full Disk
    /// Access (one started from a terminal, say) cannot read eligibility, and every launch of one flipped the state to unknown and
    /// back, with a notification each way (2026-10-05).
    public static let unknownGrace: TimeInterval = 60 * 60

    public let releaseGrace: TimeInterval

    public init(releaseGrace: TimeInterval = Self.defaultReleaseGrace) { self.releaseGrace = releaseGrace }

    /// Decides the next record and whether to alert. Alerts fire once per state, never repeatedly.
    public func transition(previous: AppleIntelligenceWatchRecord?, status: AppleIntelligenceGuardStatus) -> AppleIntelligenceWatchOutcome {
        let now = status.generatedAt
        let changed = previous?.state != status.state
        let since = changed ? now : previous!.since
        let alreadyAlerted = changed ? false : previous!.alerted

        var alert: AppleIntelligenceWatchAlert?
        if !alreadyAlerted {
            switch status.state {
            case .atRisk:
                alert = .init(severity: .warning, title: loc("Apple Intelligence is back on"),
                              message: loc("Switch it off again in MacSpace."))
            case .unknown where now.timeIntervalSince(since) >= Self.unknownGrace:
                alert = .init(severity: .warning, title: loc("Couldn't check Apple Intelligence"),
                              message: loc("Open MacSpace to check."))
            case .releasing where now.timeIntervalSince(since) >= releaseGrace:
                alert = .init(severity: .warning, title: loc("Apple Intelligence models still on disk"),
                              message: loc("Open MacSpace to free them."))
            case .protected where previous.map { $0.state != .protected && $0.warned } ?? false:
                alert = .init(severity: .info, title: loc("Apple Intelligence is off"),
                              message: loc("Its models are gone."))
            default:
                break
            }
        }
        // A lingering release or unreadable state is re-evaluated each run until its alert fires; other states are settled once seen.
        let settled = alreadyAlerted || alert != nil || (status.state != .releasing && status.state != .unknown)
        let warned = status.state != .protected && ((previous?.warned ?? false) || alert?.severity == .warning)
        let record = AppleIntelligenceWatchRecord(state: status.state, since: since, lastChecked: now, alerted: settled, warned: warned)
        return AppleIntelligenceWatchOutcome(previous: previous, record: record, transitioned: changed, alert: alert)
    }
}

/// File-backed state, log and notification handling for the watcher.
public struct AppleIntelligenceWatchStore {
    public static let supportDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MacSpace")
    public static let logDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/MacSpace")
    public static let maximumLogBytes = 512 * 1024

    public let stateURL: URL
    public let eventLogURL: URL
    private let fileManager: FileManager

    public init(stateURL: URL = supportDirectory.appendingPathComponent("ai-watch-state.json"),
                eventLogURL: URL = logDirectory.appendingPathComponent("ai-watch.jsonl"),
                fileManager: FileManager = .default) {
        self.stateURL = stateURL
        self.eventLogURL = eventLogURL
        self.fileManager = fileManager
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    public func load() -> AppleIntelligenceWatchRecord? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AppleIntelligenceWatchRecord.self, from: data)
    }

    public func save(_ record: AppleIntelligenceWatchRecord) throws {
        try fileManager.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(record).write(to: stateURL, options: .atomic)
    }

    /// Appends one JSON line per transition or alert; the log is rotated to a single `.1` file past the size limit.
    public func append(_ outcome: AppleIntelligenceWatchOutcome, status: AppleIntelligenceGuardStatus) throws {
        struct Event: Encodable { let at: Date; let state: AppleIntelligenceGuardState; let previous: AppleIntelligenceGuardState?; let alert: AppleIntelligenceWatchAlert?; let reasons: [String] }
        try fileManager.createDirectory(at: eventLogURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? fileManager.attributesOfItem(atPath: eventLogURL.path)[.size] as? NSNumber)?.intValue, size > Self.maximumLogBytes {
            let rotated = eventLogURL.appendingPathExtension("1")
            try? fileManager.removeItem(at: rotated)
            try fileManager.moveItem(at: eventLogURL, to: rotated)
        }
        var line = try Self.encoder.encode(Event(at: status.generatedAt, state: status.state, previous: outcome.previous?.state,
                                                 alert: outcome.alert, reasons: status.reasons))
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: eventLogURL) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: eventLogURL, options: .atomic)
        }
    }

    /// Posts a notification from MacSpace itself, with its icon (not `osascript`, which showed Script Editor's). macOS asks the user
    /// once whether MacSpace may notify. Outside the app (the CLI has no bundle) nothing is posted.
    public static func notify(_ alert: AppleIntelligenceWatchAlert) {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let center = UNUserNotificationCenter.current()
        let title = alert.title, message = alert.message
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = message
            // Opens the module's page when clicked (`AppNotifications`).
            content.userInfo = ["module": "com.macspace.siri"]
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
