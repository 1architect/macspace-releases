import Darwin
import Foundation

/// Fixed user controls for model-owning features. The journal preserves absent keys and complete voice dictionaries.
/// Session Language is deliberately outside this catalog: clearing it can make Apple Intelligence eligible again.
public struct ModelFeatureSettings: Sendable {
    public enum Feature: String, Codable, CaseIterable, Sendable { case siri, spatialPhotos, phone }
    public enum State: String, Codable, Sendable { case on, off, changedElsewhere, unknown, unsupported }
    public struct Status: Codable, Equatable, Sendable {
        public var state: State
        public var managedOff: Bool
        public var requestedOff: Bool?
        public init(state: State, managedOff: Bool = false, requestedOff: Bool? = nil) {
            self.state = state; self.managedOff = managedOff; self.requestedOff = requestedOff
        }
    }
    struct Slot: Sendable {
        var domain: String
        var key: String
        var off: Bool?
        var absentDefault: Bool?
        var id: String { domain + "/" + key }
    }
    struct Entry: Codable { var id: String; var before: Data? }
    struct Journal: Codable { var version = 1; var feature: Feature; var wantsOff: Bool; var entries: [Entry]; var completed = false }
    public static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/MacSpace/feature-settings")
    let directory: URL
    let supported: Bool
    let read: @Sendable (String, String) throws -> Data?
    let write: @Sendable (String, String, Data?) throws -> Void
    let notify: @Sendable (Feature) throws -> Void

    public init() {
        self.init(directory: Self.directory, supported: PhoneFeatureFlags.supported.value, read: Self.readPreference,
                  write: Self.writePreference, notify: Self.notify)
    }
    init(directory: URL, supported: Bool = true,
         read: @escaping @Sendable (String, String) throws -> Data?,
         write: @escaping @Sendable (String, String, Data?) throws -> Void,
         notify: @escaping @Sendable (Feature) throws -> Void = { _ in }) {
        self.directory = directory; self.supported = supported; self.read = read; self.write = write; self.notify = notify
    }
    static func slots(_ feature: Feature) -> [Slot] {
        switch feature {
        case .siri: return [Slot(domain: "com.apple.assistant.support", key: "Assistant Enabled", off: false),
                            Slot(domain: "com.apple.assistant.backedup", key: "Output Voice", off: nil)]
        case .spatialPhotos: return [Slot(domain: "com.apple.spatialphotosrelive", key: "LocallyDisabled", off: true, absentDefault: false)]
        case .phone: return [Slot(domain: "com.apple.TelephonyUtilities", key: "CallRecordingDisabled", off: true, absentDefault: false),
                             Slot(domain: "com.apple.TelephonyUtilities", key: "CallScreeningDisabled", off: true, absentDefault: false),
                             Slot(domain: "com.apple.Accessibility", key: "FaceTimeCaptions", off: false, absentDefault: false),
                             Slot(domain: "com.apple.Accessibility", key: "LiveTranscriptionInCallEnabled", off: false, absentDefault: false)]
        }
    }
    static func pack(_ value: Any) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: ["value": value], format: .binary, options: 0)
    }
    static func unpack(_ data: Data) throws -> Any {
        guard let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any], let value = root["value"] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return value
    }
    static func equal(_ lhs: Data?, _ rhs: Data?) throws -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return try NSDictionary(dictionary: ["value": unpack(lhs)]).isEqual(to: ["value": unpack(rhs)])
    }
    func url(_ feature: Feature) -> URL { directory.appendingPathComponent(feature.rawValue + ".json") }
    func load(_ feature: Feature) throws -> Journal? {
        guard FileManager.default.fileExists(atPath: url(feature).path) else { return nil }
        let journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: url(feature)))
        guard journal.version == 1, journal.feature == feature, journal.entries.map(\.id) == Self.slots(feature).map(\.id) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return journal
    }
    func save(_ journal: Journal) throws {
        try JSONEncoder().encode(journal).write(to: url(journal.feature), options: [.atomic])
        guard chmod(url(journal.feature).path, 0o600) == 0 else { throw POSIXError(.EACCES) }
        let fd = open(url(journal.feature).path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw POSIXError(.EIO) }; defer { close(fd) }
        guard fsync(fd) == 0 else { throw POSIXError(.EIO) }
    }
    public func status(_ feature: Feature) -> Status {
        do {
            let journal = try load(feature)
            guard supported else { return Status(state: .unsupported, requestedOff: journal?.wantsOff) }
            let slots = Self.slots(feature)
            let values = try slots.map { try read($0.domain, $0.key) }
            let matches = try zip(slots, values).allSatisfy { slot, data in
                guard let off = slot.off else { return data == nil }
                if data == nil { return slot.absentDefault == off }
                guard let value = try Self.unpack(data!) as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return false }
                return value.boolValue == off
            }
            if journal?.wantsOff == true {
                return Status(state: matches ? .off : .changedElsewhere, managedOff: matches, requestedOff: true)
            }
            if feature == .siri, values.first! == nil { return Status(state: .unknown) }
            if feature == .siri, let data = values.first!, let enabled = try Self.unpack(data) as? NSNumber {
                return Status(state: enabled.boolValue ? .on : .off)
            }
            return Status(state: matches ? .off : .on)
        } catch { return Status(state: .unknown) }
    }
    public func hasSavedSettings(_ feature: Feature) -> Bool {
        do { return try load(feature).map { $0.wantsOff || !$0.completed } ?? false } catch { return true }
    }

    /// Saves intent before the first write; interrupted changes can resume only at their recorded endpoints.
    public func setOff(_ off: Bool, feature: Feature) throws {
        guard getuid() != 0 else { throw POSIXError(.EPERM) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(directory.appendingPathComponent("settings.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(.EACCES) }; defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw POSIXError(.EBUSY) }; defer { flock(fd, LOCK_UN) }
        let slots = Self.slots(feature)
        var journal = try load(feature)
        if off {
            guard supported else { throw POSIXError(.ENOTSUP) }
            if journal == nil || journal?.wantsOff == false && journal?.completed == true {
                journal = Journal(feature: feature, wantsOff: true, entries: try slots.map { Entry(id: $0.id, before: try read($0.domain, $0.key)) })
            }
        } else if journal == nil || journal?.wantsOff == false && journal?.completed == true {
            // No owned settings to restore. Enabling Siri/Spatial Photos is still an explicit user request.
            if feature == .siri { try write(slots[0].domain, slots[0].key, Self.pack(true)) }
            if feature == .spatialPhotos { try write(slots[0].domain, slots[0].key, nil) }
            try notify(feature)
            return
        }
        guard var journal else { return }
        for (slot, entry) in zip(slots, journal.entries) {
            let current = try read(slot.domain, slot.key)
            let disabled = try slot.off.map(Self.pack)
            guard try Self.equal(current, entry.before) || Self.equal(current, disabled) else { throw POSIXError(.ESTALE) }
        }
        journal.wantsOff = off
        journal.completed = false
        try save(journal)
        for (slot, entry) in zip(slots, journal.entries) {
            let destination = try off ? slot.off.map(Self.pack) : entry.before
            try write(slot.domain, slot.key, destination)
            guard try Self.equal(read(slot.domain, slot.key), destination) else { throw POSIXError(.EIO) }
        }
        try notify(feature)
        journal.completed = true
        try save(journal)
    }

    static func readPreference(_ domain: String, _ key: String) throws -> Data? {
        guard CFPreferencesSynchronize(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else { throw POSIXError(.EIO) }
        return try CFPreferencesCopyValue(key as CFString, domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost).map(pack)
    }
    static func writePreference(_ domain: String, _ key: String, _ data: Data?) throws {
        let value = try data.map(unpack)
        CFPreferencesSetValue(key as CFString, value as CFPropertyList?, domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else { throw POSIXError(.EIO) }
    }
    static func notify(_ feature: Feature) throws {
        let names: [DarwinNotificationName]
        switch feature {
        case .siri: names = [.exported(framework: "/System/Library/PrivateFrameworks/AssistantServices.framework/AssistantServices", symbol: "AFAssistantEnablementDidChangeDarwinNotification"),
                             .exported(framework: "/System/Library/PrivateFrameworks/AssistantServices.framework/AssistantServices", symbol: "AFLanguageCodeDidChangeDarwinNotification")]
        case .spatialPhotos: names = [.literal("com.apple.spatialphotosrelive.enablement.changed")]
        case .phone: names = [.literal("com.apple.accessibility.facetime.captions.changed"), .literal("com.apple.accessibility.live.transcription.in.call.enabled")]
        }
        for name in names { guard name.post() != nil else { throw POSIXError(.ENOTSUP) } }
    }
}
