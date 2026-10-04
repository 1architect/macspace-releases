import Foundation

/// Every cleanup MacSpace made, kept for Settings: when, which module, how much it freed and how it started. The lifetime total is
/// the sum of every entry, kept even when old entries are trimmed.
public final class CleanupHistory: @unchecked Sendable {
    public enum Trigger: String, Codable, Sendable {
        /// The user pressed a button.
        case manual
        /// Automatic cleanup, from Settings.
        case automatic
        /// MacSpace finished a cleanup by itself (released models deleted, macOS asked again for files it had kept).
        case background
    }

    public struct Entry: Codable, Equatable, Sendable, Identifiable {
        public var id: UUID
        public var date: Date
        public var moduleID: String
        public var moduleName: String
        public var freedBytes: UInt64
        public var trigger: Trigger
        public var summary: String

        public init(id: UUID = UUID(), date: Date = Date(), moduleID: String, moduleName: String, freedBytes: UInt64, trigger: Trigger, summary: String) {
            self.id = id
            self.date = date
            self.moduleID = moduleID
            self.moduleName = moduleName
            self.freedBytes = freedBytes
            self.trigger = trigger
            self.summary = summary
        }
    }

    struct Store: Codable {
        var entries: [Entry] = []
        /// Bytes freed by entries trimmed from `entries`, so the lifetime total never shrinks.
        var trimmedBytes: UInt64 = 0
    }

    public static let shared = CleanupHistory()
    public static let didChange = Notification.Name("com.macspace.cleanupHistoryDidChange")
    public static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/MacSpace/cleanup-history.json")
    /// Entries kept one by one; older ones only count toward the total.
    static let keptEntries = 500
    /// Below this, a cleanup is the system's own churn, not worth an entry.
    public static let minimumBytes: UInt64 = 1_000_000

    private let url: URL
    private let lock = NSLock()
    private var store: Store

    public init(url: URL = CleanupHistory.defaultURL) {
        self.url = url
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        store = (try? Data(contentsOf: url)).flatMap { try? decoder.decode(Store.self, from: $0) } ?? Store()
    }

    /// Newest first.
    public var entries: [Entry] {
        lock.lock(); defer { lock.unlock() }
        return store.entries.reversed()
    }

    public var lifetimeBytes: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return store.entries.reduce(store.trimmedBytes) { $0 + $1.freedBytes }
    }

    /// Records a cleanup; one that freed less than `minimumBytes` is left out.
    public func record(moduleID: String, moduleName: String, freedBytes: UInt64, trigger: Trigger, summary: String, date: Date = Date()) {
        guard freedBytes >= Self.minimumBytes else { return }
        lock.lock()
        store.entries.append(Entry(date: date, moduleID: moduleID, moduleName: moduleName, freedBytes: freedBytes, trigger: trigger, summary: summary))
        if store.entries.count > Self.keptEntries {
            let dropped = store.entries.prefix(store.entries.count - Self.keptEntries)
            store.trimmedBytes += dropped.reduce(0) { $0 + $1.freedBytes }
            store.entries.removeFirst(dropped.count)
        }
        let snapshot = store
        lock.unlock()
        save(snapshot)
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.didChange, object: nil) }
    }

    private func save(_ store: Store) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(store) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
