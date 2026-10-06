import Foundation
@preconcurrency import UserNotifications

/// A feature macOS switched back on and the background watch switched off again.
struct DebloatReapplied: Codable, Equatable, Sendable {
    var at: Date
    var titles: [String]
}

/// What the watch switched off again, kept a few days so the page can say so. In the user's Application Support, next to the undo
/// journal.
struct DebloatWatchStore {
    /// How long the page mentions a feature switched off again.
    static let shownFor: TimeInterval = 3 * 86_400
    static let maximumEvents = 20

    let url: URL
    var fileManager = FileManager.default

    init(url: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MacSpace/debloat-watch.json")) {
        self.url = url
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    func load() -> [DebloatReapplied] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? Self.decoder.decode([DebloatReapplied].self, from: data)) ?? []
    }

    /// The events still worth showing, newest first.
    func recent(now: Date = Date()) -> [DebloatReapplied] {
        load().filter { now.timeIntervalSince($0.at) < Self.shownFor }.sorted { $0.at > $1.at }
    }

    func record(_ event: DebloatReapplied) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let events = Array((load() + [event]).sorted { $0.at < $1.at }.suffix(Self.maximumEvents))
        try Self.encoder.encode(events).write(to: url, options: .atomic)
    }

    /// Posts a notification from MacSpace itself; macOS asks the user once whether MacSpace may notify. Outside the app (the CLI
    /// has no bundle) nothing is posted.
    static func notify(_ event: DebloatReapplied) {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let center = UNUserNotificationCenter.current()
        let title = event.titles.count == 1 ? "\(event.titles[0]) was turned back on" : "\(event.titles.count) features were turned back on"
        let body = "macOS switched \(event.titles.joined(separator: ", ")) back on. MacSpace disabled \(event.titles.count == 1 ? "it" : "them") again."
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
