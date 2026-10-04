import Foundation
import MacSpaceSdk

/// Which configuration profiles are installed, read the way any user can: `system_profiler SPConfigurationProfileDataType`, which
/// lists the device profiles with their identifiers (`profiles list` needs root). Takes about 0.1 s, so the answer is cached and
/// refreshed in the background.
public final class ConfigurationProfiles: @unchecked Sendable {
    public static let shared = ConfigurationProfiles()
    /// Every MacSpace profile's identifier starts with it (`ConfigurationProfileBuilder` in Debloat).
    public static let macSpacePrefix = "com.macspace.policies"
    static let maxAge: TimeInterval = 10

    private let lock = NSLock()
    private var cached: (identifiers: Set<String>?, at: Date)?
    private var refreshing = false
    private let read: @Sendable () -> Set<String>?

    public init(read: @escaping @Sendable () -> Set<String>? = ConfigurationProfiles.readInstalled) {
        self.read = read
    }

    /// Granted while a MacSpace profile is installed, missing while none is, unknown until the first reading (or when it fails).
    public func status(now: Date = Date()) -> PermissionStatus {
        lock.lock()
        let current = cached
        let stale = current.map { now.timeIntervalSince($0.at) >= Self.maxAge } ?? true
        let start = stale && !refreshing
        if start { refreshing = true }
        lock.unlock()
        if start { refresh() }
        guard let identifiers = current?.identifiers else { return .unknown }
        return Self.status(identifiers)
    }

    /// Reads now, in the background; `status` answers from the last reading meanwhile.
    public func refresh() {
        let read = self.read
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let identifiers = read()
            guard let self else { return }
            self.lock.lock()
            self.cached = (identifiers, Date())
            self.refreshing = false
            self.lock.unlock()
        }
    }

    /// Reads now and waits for it.
    public func refreshNow() {
        let identifiers = read()
        lock.lock()
        cached = (identifiers, Date())
        lock.unlock()
    }

    public static func status(_ identifiers: Set<String>) -> PermissionStatus {
        identifiers.contains { $0.hasPrefix(macSpacePrefix) } ? .granted : .missing
    }

    public static func readInstalled() -> Set<String>? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPConfigurationProfileDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return parse(data)
    }

    /// Every `spconfigprofile_profile_identifier` in the report, at any depth (user and device sections).
    public static func parse(_ data: Data) -> Set<String>? {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var found: Set<String> = []
        func walk(_ value: Any) {
            if let dictionary = value as? [String: Any] {
                if let identifier = dictionary["spconfigprofile_profile_identifier"] as? String { found.insert(identifier) }
                dictionary.values.forEach(walk)
            } else if let array = value as? [Any] {
                array.forEach(walk)
            }
        }
        walk(root)
        return found
    }
}
