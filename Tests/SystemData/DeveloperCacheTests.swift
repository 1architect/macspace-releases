import XCTest
import MacSpaceSdk
@testable import MacSpaceSystemData

/// Developer tools' caches (`DeveloperCaches`) and the saved form of the rows that show them.
final class DeveloperCacheTests: XCTestCase {
    private var home: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        home = fm.temporaryDirectory.appendingPathComponent("macspace-devcache-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: home) }

    private func folder(_ path: String, bytes: Int = 2_000_000) throws -> URL {
        let url = home.appendingPathComponent(path)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url.appendingPathComponent("blob"))
        return url
    }

    /// Build files of a project that is gone, and device files of every version but the newest, are recommended; a package manager's
    /// cache in use is listed without a reason.
    func testRecommendsWhatNoProjectOrDeviceNeeds() throws {
        let gone = try folder("Library/Developer/Xcode/DerivedData/OldApp-abcdef")
        NSDictionary(dictionary: ["WorkspacePath": home.appendingPathComponent("nowhere/OldApp.xcodeproj").path])
            .write(to: gone.appendingPathComponent("info.plist"), atomically: true)
        let project = home.appendingPathComponent("Live.xcodeproj")
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        let live = try folder("Library/Developer/Xcode/DerivedData/Live-123456")
        NSDictionary(dictionary: ["WorkspacePath": project.path]).write(to: live.appendingPathComponent("info.plist"), atomically: true)
        _ = try folder("Library/Developer/Xcode/iOS DeviceSupport/18.9 (22A1)")
        _ = try folder("Library/Developer/Xcode/iOS DeviceSupport/18.10 (22B1)")
        _ = try folder("Library/Caches/pip")
        let found = Dictionary(uniqueKeysWithValues: DeveloperCaches.scan(home: home.path).map { ($0.id, $0) })
        XCTAssertEqual(found["dev:derived:OldApp-abcdef"]?.reason, "Project deleted")
        XCTAssertEqual(found["dev:derived:OldApp-abcdef"]?.title, "Xcode builds: OldApp")
        XCTAssertNil(found["dev:derived:Live-123456"]?.reason)
        XCTAssertEqual(found["dev:support:iOS:18.9 (22A1)"]?.reason, "Older version", "18.10 is newer than 18.9")
        XCTAssertNil(found["dev:support:iOS:18.10 (22B1)"]?.reason)
        XCTAssertNotNil(found["dev:pip"])
        XCTAssertNil(found["dev:pip"]?.reason, "changed today")
    }

    /// The folders of ~/Library/Caches and ~/.cache claimed here are not listed again as an app's or a tool's cache.
    func testClaimedFoldersAreListedOnce() {
        XCTAssertTrue(DeveloperCaches.claimedLibraryCaches.isSuperset(of: ["pip", "org.swift.swiftpm", "bun", "Yarn"]))
        XCTAssertTrue(DeveloperCaches.claimedToolCaches.isSuperset(of: ["uv", "pre-commit"]))
        XCTAssertFalse(DeveloperCaches.claimedToolCaches.contains("codex-runtimes"), "an app's runtime is not a cache")
    }

    /// A row saved before rows had several pills still opens, with its one pill.
    func testARowSavedWithOneBadgeStillDecodes() throws {
        let json = #"{"id":"r","title":"T","badge":{"text":"Old","tone":{"neutral":{}}},"steps":[],"actions":[]}"#
        let row = try JSONDecoder().decode(Row.self, from: Data(json.utf8))
        XCTAssertEqual(row.badges.map(\.text), ["Old"])
        let again = try JSONDecoder().decode(Row.self, from: JSONEncoder().encode(Row(id: "r", title: "T", badges: [Badge("A", .info), Badge("B", .action)])))
        XCTAssertEqual(again.badges.map(\.text), ["A", "B"])
        XCTAssertEqual(row.badges.map(\.kind), [.info], "a pill saved with a tone reads as a description")
        XCTAssertEqual(again.badges.map(\.kind), [.info, .action])
    }
}
