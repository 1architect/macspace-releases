import XCTest
import MacSpaceSdk
import MacSpacePlatform
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
    func testOnlyVerifiedProjectOutputsAreOffered() throws {
        let swift = try folder("Projects/Swift/.build"), rust = try folder("Projects/Rust/target")
        try Data().write(to: home.appendingPathComponent("Projects/Swift/Package.swift"))
        try Data().write(to: swift.appendingPathComponent("workspace-state.json"))
        try Data().write(to: home.appendingPathComponent("Projects/Rust/Cargo.toml"))
        try Data().write(to: rust.appendingPathComponent(".rustc_info.json"))
        _ = try folder("Projects/Personal/target")
        let outputs = DeveloperCaches.projectOutputs(home: home.resolvingSymlinksInPath().path)
        XCTAssertEqual(Set(outputs.map { ($0.path as NSString).lastPathComponent }), [".build", "target"])
        XCTAssertEqual(outputs.count, 2)
    }

    func testProjectOutputCannotApproveSiblingSourceOrLinkedMetadata() throws {
        let output = try folder("Documents/Rust/target", bytes: 1)
        let project = output.deletingLastPathComponent()
        try Data().write(to: project.appendingPathComponent("Cargo.toml"))
        let marker = output.appendingPathComponent(".rustc_info.json")
        try Data().write(to: marker)
        let canonicalHome = home.resolvingSymlinksInPath().path
        let canonicalOutput = output.resolvingSymlinksInPath().path
        XCTAssertTrue(DeveloperCaches.verifiedProjectOutput(canonicalOutput, home: canonicalHome))
        XCTAssertFalse(FileReviewPolicy.includes(canonicalOutput + "/artifact", home: canonicalHome), "Disk must leave generated output to System Data")
        XCTAssertFalse(FileReviewPolicy.includes(canonicalHome + "/Documents/Swift/.build/debug/bin", home: canonicalHome))
        let source = try folder("Documents/Rust/src", bytes: 1)
        let item = SystemDataItem(id: "source", title: "source", kind: .toolCache, paths: [source.path], bytes: 1,
                                  readable: true, owners: [], inUse: false,
                                  cleanup: .init(kind: .deleteWhenNotRunning, description: "", command: nil), notes: [])
        let cleaner = SystemDataCleaner(runningApps: { [] }, processCheck: .none, freeSpace: { nil })
        let result = cleaner.clean([item], allowedRoots: [], allowedPaths: [canonicalOutput])
        XCTAssertFalse(result.results[0].deleted)
        XCTAssertTrue(fm.fileExists(atPath: source.path))
        try fm.removeItem(at: marker)
        try fm.createSymbolicLink(at: marker, withDestinationURL: project.appendingPathComponent("Cargo.toml"))
        XCTAssertFalse(DeveloperCaches.verifiedProjectOutput(canonicalOutput, home: canonicalHome))
    }

    func testLinkedCacheAncestorCannotEscapeApprovedRoot() throws {
        let caches = try folder("Library/Caches", bytes: 1)
        let personal = try folder("Documents/Personal", bytes: 1)
        let link = caches.appendingPathComponent("linked")
        try fm.createSymbolicLink(at: link, withDestinationURL: personal)
        let item = SystemDataItem(id: "link", title: "link", kind: .appCache, paths: [link.appendingPathComponent("blob").path], bytes: 1,
                                  readable: true, owners: [], inUse: false,
                                  cleanup: .init(kind: .deleteWhenNotRunning, description: "", command: nil), notes: [])
        let result = SystemDataCleaner(runningApps: { [] }, processCheck: .none, freeSpace: { nil }).clean([item], allowedRoots: [caches.path])
        XCTAssertFalse(result.results[0].deleted)
        XCTAssertTrue(fm.fileExists(atPath: personal.appendingPathComponent("blob").path))
    }

    func testCleanupBatchesKeepOverlapsAndHomebrewSerial() {
        func entry(_ id: String, _ path: String, _ source: CacheEntry.Source = .developer) -> CacheEntry {
            CacheEntry(id: id, title: id, bytes: 1, paths: [path], source: source)
        }
        let entries = [entry("a", "/a"), entry("b", "/b"), entry("nested", "/b/sub"), entry("brew", "/brew", .homebrew), entry("c", "/c")]
        let batches = SystemDataModule.cacheCleanupBatches(entries)
        XCTAssertEqual(batches.map { $0.map(\.id) }, [["a", "b"], ["nested"], ["brew"], ["c"]])
        XCTAssertTrue(batches.allSatisfy { $0.count <= 2 })
    }

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
