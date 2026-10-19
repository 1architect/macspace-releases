import Darwin
import Foundation

/// The reviewed upstream Phone gates. Feature management stays in Siri; this shared, UI-independent implementation is also
/// available to its helper handler. Root callers expose only the fixed on/off operation, never a path/domain/key from a request.
public struct PhoneFeatureFlags: Sendable {
    public static let domain = "TelephonyUtilities"
    public static let features = ["CallRecording", "CallScreeningEnabled", "CaptionDeliveryForFaceTime",
                                  "AudioCallTranslationMac", "VideoCallTranslationMac"]
    public static let supported = ReleaseSpecific(false, overrides: [(.major(27), true)])

    public enum State: String, Codable, Sendable { case on, off, restartRequired, changedElsewhere, unknown, unsupported }
    public struct Status: Codable, Sendable, Equatable {
        public var state: State
        /// True only after this control durably recorded an explicit off intent and all gates verified off.
        public var managedOff: Bool
        public var effective: [String: Bool]
        public var detail: String?
        public var requestedOff: Bool?

        public init(state: State, managedOff: Bool, effective: [String: Bool], detail: String? = nil, requestedOff: Bool? = nil) {
            self.state = state; self.managedOff = managedOff; self.effective = effective
            self.detail = detail; self.requestedOff = requestedOff
        }
    }

    struct Entry: Codable, Sendable {
        var feature: String
        var before: Data?
        var disabled: Data
    }
    struct Journal: Codable, Sendable {
        var version = 1
        var wantsOff: Bool
        var entries: [Entry]
        var originalEffective: [String: Bool]?
        var changedDuringBoot: String?
        var writeCompleted: Bool?
    }

    let overrideURL: URL
    let journalURL: URL
    let supported: Bool
    let effective: @Sendable (String) -> Bool?
    let declared: @Sendable (String) -> Bool
    let requiresRoot: Bool
    let bootSession: @Sendable () -> String?

    public init() {
        self.init(overrideURL: URL(fileURLWithPath: "\(FeatureFlagOverrides.directory)/\(Self.domain).plist"),
                  journalURL: URL(fileURLWithPath: "/Library/Application Support/MacSpace/phone-features.json"),
                  supported: Self.supported.value,
                  effective: { FeatureFlagOverrides.effectiveValue(domain: Self.domain, feature: $0) },
                  declared: { FeatureFlagOverrides.isDeclared(domain: Self.domain, feature: $0) }, requiresRoot: true,
                  bootSession: Self.currentBoot)
    }

    init(overrideURL: URL, journalURL: URL, supported: Bool = true,
         effective: @escaping @Sendable (String) -> Bool?, declared: @escaping @Sendable (String) -> Bool = { _ in true },
         requiresRoot: Bool = false, bootSession: @escaping @Sendable () -> String? = PhoneFeatureFlags.currentBoot) {
        self.overrideURL = overrideURL; self.journalURL = journalURL
        self.supported = supported; self.effective = effective; self.declared = declared; self.requiresRoot = requiresRoot
        self.bootSession = bootSession
    }

    public func status() -> Status {
        do {
            let journal = try load()
            func result(_ state: State, managedOff: Bool = false, values: [String: Bool], detail: String? = nil) -> Status {
                Status(state: state, managedOff: managedOff, effective: values, detail: detail, requestedOff: journal?.wantsOff)
            }
            guard supported else { return result(.unsupported, values: [:]) }
            var values: [String: Bool] = [:]
            for feature in Self.features {
                guard declared(feature), let value = effective(feature) else {
                    return result(.unknown, values: values, detail: "A Phone feature gate could not be read.")
                }
                values[feature] = value
            }
            if let journal {
                // After a completed restore, later external changes are no longer this control's to report.
                if journal.wantsOff || journal.writeCompleted != true {
                    let matches = try journal.entries.allSatisfy { entry in
                        try Self.equal(current(entry.feature), journal.wantsOff ? entry.disabled : entry.before)
                    }
                    guard matches else { return result(.changedElsewhere, values: values) }
                    if journal.wantsOff {
                        let off = values.values.allSatisfy { !$0 }
                        return result(off ? .off : .restartRequired, managedOff: off, values: values)
                    }
                }
                // Restore the measured original state, which can intentionally include false. A journal without effective
                // originals requires a different boot before classifying that restoration as complete.
                let originalsMatch = journal.originalEffective.map { $0 == values } ?? false
                let restarted = journal.changedDuringBoot.flatMap { before in bootSession().map { $0 != before } } ?? false
                if !originalsMatch && !restarted { return result(.restartRequired, values: values) }
            }
            return result(values.values.allSatisfy { !$0 } ? .off : .on, values: values)
        } catch { return Status(state: .unknown, managedOff: false, effective: [:], detail: error.localizedDescription) }
    }

    public var hasSavedSettings: Bool {
        do { return try load().map { $0.wantsOff || $0.writeCompleted != true } ?? false }
        catch { return true } // unreadable rollback state must stop uninstall, not be silently abandoned
    }

    /// Called in the authenticated helper. Nothing is changed before the full rollback/intent journal has been persisted.
    public func setOff(_ off: Bool) throws -> Status {
        guard !requiresRoot || geteuid() == 0 else { throw failure("Changing the Phone gates requires the MacSpace helper.") }
        if off, !supported || !Self.features.allSatisfy(declared) { throw failure("The Phone gates have not been verified on this macOS build.") }
        return try withLock {
            var journal = try load()
            var pendingOriginals: [String: Bool]?
            var usesPendingOriginals = false
            if let previous = journal, !previous.wantsOff, previous.writeCompleted == true {
                if !off { return status() } // already restored: a later external change is no longer ours to undo
                // A new off action gets a new baseline. If the preceding restore still needs this boot to end, keep its
                // effective originals only when its on-disk entries are still unchanged.
                if previous.changedDuringBoot == nil || bootSession() == nil || previous.changedDuringBoot == bootSession() {
                    usesPendingOriginals = true
                    if try previous.entries.allSatisfy({ try Self.equal(current($0.feature), $0.before) }) {
                        pendingOriginals = previous.originalEffective
                    }
                }
                journal = nil
            }
            if journal == nil {
                guard off else { throw failure("MacSpace has no saved Phone feature settings to restore.") }
                var originals: [String: Bool] = [:]
                for feature in Self.features {
                    guard let value = effective(feature) else { throw failure("A Phone feature gate could not be read.") }
                    originals[feature] = value
                }
                let entries = try Self.features.map { feature in
                    let before = try current(feature)
                    if let before, let explicit = try Self.dictionary(before)["Enabled"] as? Bool { originals[feature] = explicit }
                    return Entry(feature: feature, before: before, disabled: try Self.disabling(before))
                }
                journal = Journal(wantsOff: true, entries: entries, originalEffective: usesPendingOriginals ? pendingOriginals : originals)
            }
            var intent = journal!
            // Check ALL entries before any change. Either endpoint allows recovery after an interrupted operation; a third
            // value is another writer's change and must not be overwritten, even when that value would also disable a feature.
            for entry in intent.entries {
                let value = try current(entry.feature)
                guard try Self.equal(value, entry.before) || Self.equal(value, entry.disabled) else {
                    throw failure("A Phone feature override changed outside MacSpace: \(entry.feature).")
                }
            }
            intent.wantsOff = off
            intent.changedDuringBoot = bootSession()
            intent.writeCompleted = false
            try save(intent)
            for entry in intent.entries {
                try FeatureFlagOverrides.restore(feature: entry.feature, entry: off ? entry.disabled : entry.before, path: overrideURL.path)
            }
            for entry in intent.entries {
                guard try Self.equal(current(entry.feature), off ? entry.disabled : entry.before) else {
                    throw failure("A Phone feature override did not verify: \(entry.feature).")
                }
            }
            intent.writeCompleted = true
            try save(intent)
            return status()
        }
    }

    func current(_ feature: String) throws -> Data? { try FeatureFlagOverrides.entry(feature: feature, path: overrideURL.path) }
    static func dictionary(_ data: Data) throws -> [String: Any] {
        guard let value = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw NSError(domain: "MacSpace.PhoneFeatures", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unrecognized Phone feature entry."])
        }
        return value
    }
    static func disabling(_ before: Data?) throws -> Data {
        var value = try before.map(dictionary) ?? [:]
        value.removeValue(forKey: "DevelopmentPhase"); value["Enabled"] = false
        return try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
    }
    static func equal(_ a: Data?, _ b: Data?) throws -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return try NSDictionary(dictionary: dictionary(a)).isEqual(to: dictionary(b))
        default: return false
        }
    }
    func validate(_ journal: Journal) throws {
        guard journal.version == 1, journal.entries.count == Self.features.count,
              Set(journal.entries.map(\.feature)) == Set(Self.features) else { throw failure("Unrecognized Phone feature journal.") }
        if let originals = journal.originalEffective, Set(originals.keys) != Set(Self.features) {
            throw failure("Incomplete original Phone feature state.")
        }
        for entry in journal.entries {
            guard try Self.equal(entry.disabled, Self.disabling(entry.before)) else { throw failure("Invalid Phone feature rollback entry.") }
        }
    }
    func load() throws -> Journal? {
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return nil }
        if requiresRoot { try validateRootPaths([journalURL, overrideURL]) }
        let value = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: journalURL))
        try validate(value)
        return value
    }
    func save(_ journal: Journal) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(journal).write(to: journalURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: journalURL.path)
        let handle = try FileHandle(forWritingTo: journalURL)
        defer { try? handle.close() }
        try handle.synchronize()
        let directory = open(journalURL.deletingLastPathComponent().path, O_RDONLY)
        guard directory >= 0 else { throw failure("Could not persist the Phone feature journal directory.") }
        defer { close(directory) }
        guard fsync(directory) == 0 else { throw failure("Could not persist the Phone feature journal directory.") }
    }
    func withLock<T>(_ body: () throws -> T) throws -> T {
        let directory = journalURL.deletingLastPathComponent()
        // The public initializer is the root helper's fixed path. Refuse symlinks/writable parents and journals before touching
        // privileged state. Fixture instances use only their test directory.
        if requiresRoot { try validateRootPaths([overrideURL, journalURL]) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let descriptor = open(journalURL.path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw failure("Could not lock the Phone feature journal.") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw failure("Could not lock the Phone feature journal.") }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
    func validateRootPaths(_ urls: [URL]) throws {
        for url in urls {
            var item = url
            while item.path != "/" {
                var info = stat()
                if lstat(item.path, &info) == 0 {
                    guard info.st_uid == 0, info.st_mode & 0o022 == 0, info.st_mode & S_IFMT != S_IFLNK else {
                        throw failure("Unsafe Phone feature path: \(item.path).")
                    }
                } else if errno != ENOENT { throw failure("Could not verify the Phone feature path.") }
                item.deleteLastPathComponent()
            }
        }
    }
    static func currentBoot() -> String? {
        var count = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &count, nil, 0) == 0, count > 1 else { return nil }
        var value = [CChar](repeating: 0, count: count)
        guard sysctlbyname("kern.bootsessionuuid", &value, &count, nil, 0) == 0 else { return nil }
        return String(decoding: value.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
    func failure(_ message: String) -> NSError { NSError(domain: "MacSpace.PhoneFeatures", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
