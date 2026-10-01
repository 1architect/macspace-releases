import Foundation

public protocol DebloatJournalStoring: AnyObject {
    func load(_ privilege: DebloatPrivilege) -> DebloatJournal
    func save(_ journal: DebloatJournal, _ privilege: DebloatPrivilege) throws
}

public extension DebloatJournalStoring {
    var allEntries: [JournalEntry] { load(.user).entries + load(.root).entries }
}

/// Two journals, matching the two privileges that make changes: user-scoped changes are recorded in the
/// user's Application Support, root-scoped changes in /Library/Application Support (world-readable).
public final class DebloatJournalStore: DebloatJournalStoring {
    public static let fileName = "debloat-journal.json"
    public static let systemURL = URL(fileURLWithPath: "/Library/Application Support/MacSpace").appendingPathComponent(fileName)

    public static func userURL(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/MacSpace").appendingPathComponent(fileName)
    }

    public let userURL: URL?
    public let systemURL: URL
    private let fileManager: FileManager

    public init(userURL: URL?, systemURL: URL = DebloatJournalStore.systemURL, fileManager: FileManager = .default) {
        self.userURL = userURL
        self.systemURL = systemURL
        self.fileManager = fileManager
    }

    public convenience init(targetUser: DebloatTargetUser?) {
        self.init(userURL: targetUser.map { Self.userURL(home: $0.home) })
    }

    private func url(_ privilege: DebloatPrivilege) -> URL? { privilege == .root ? systemURL : userURL }

    public func load(_ privilege: DebloatPrivilege) -> DebloatJournal {
        guard let url = url(privilege), let data = try? Data(contentsOf: url) else { return DebloatJournal() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(DebloatJournal.self, from: data)) ?? DebloatJournal()
    }

    public func save(_ journal: DebloatJournal, _ privilege: DebloatPrivilege) throws {
        guard let url = url(privilege) else { throw DebloatSystemError.targetUserUnknown }
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: privilege == .root ? [.posixPermissions: 0o755] : nil)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(journal).write(to: url, options: .atomic)
        if privilege == .root { try? fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
    }
}
