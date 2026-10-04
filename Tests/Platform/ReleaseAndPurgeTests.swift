import XCTest
import MacSpacePlatform

final class MacOSReleaseTests: XCTestCase {
    private let beta = MacOSRelease(major: 27, minor: 2, build: "26B5091g")
    private let release = MacOSRelease(major: 27, minor: 2, patch: 1, build: "26C101")

    func testDescribesTheRelease() {
        XCTAssertEqual(beta.description, "macOS 27.2 (26B5091g), beta")
        XCTAssertEqual(release.description, "macOS 27.2.1 (26C101)")
        XCTAssertTrue(beta.isPrerelease)
        XCTAssertFalse(release.isPrerelease)
        XCTAssertFalse(MacOSRelease(major: 13, minor: 3, build: "22E772610a").isPrerelease, "a Rapid Security Response is not a beta")
    }

    func testReleaseSpecificValuesTakeTheFirstMatchingOverride() {
        let wait = ReleaseSpecific(5.0, overrides: [(.build("26B5091g"), 8.0), (.major(27), 6.0)])
        XCTAssertEqual(wait.value(on: beta), 8.0)
        XCTAssertEqual(wait.value(on: release), 6.0)
        XCTAssertEqual(wait.value(on: MacOSRelease(major: 26, minor: 4)), 5.0, "every other release gets the standard value")
        let range = ReleaseMatch.versions(from: MacOSRelease(major: 27, minor: 1), through: MacOSRelease(major: 27, minor: 2, patch: 9))
        XCTAssertTrue(range.matches(release))
        XCTAssertFalse(range.matches(MacOSRelease(major: 27, minor: 3)))
    }

    func testSupportedReleases() {
        XCTAssertTrue(SupportedReleases.isSupported(beta))
        XCTAssertFalse(SupportedReleases.isSupported(MacOSRelease(major: 26, minor: 4)))
    }
}

final class PurgeRetrierTests: XCTestCase {
    private static func result(_ purged: UInt64) -> CacheDeletePurgeResult {
        CacheDeletePurgeResult(services: ["svc"], purgedBytes: purged, freeBytesBefore: 0, freeBytesAfter: purged, elapsedSeconds: 0.1, error: nil)
    }

    /// macOS kept the files: MacSpace asks again by itself, and stops once macOS lets them go.
    func testKeepsAskingUntilMacOSFreesThem() async throws {
        final class Attempts: @unchecked Sendable { var n = 0 }
        let attempts = Attempts()
        let retrier = PurgeRetrier()
        let freed = expectation(description: "freed")
        retrier.schedule(service: "svc", urgency: 4, delays: [0.05, 0.05, 0.05], purge: {
            attempts.n += 1
            return Self.result(attempts.n < 2 ? 0 : 50_000_000)
        }) { bytes in
            XCTAssertEqual(bytes, 50_000_000)
            freed.fulfill()
        }
        XCTAssertTrue(retrier.isRetrying("svc"), "the page shows it is being freed")
        await fulfillment(of: [freed], timeout: 2)
        XCTAssertEqual(attempts.n, 2, "no more requests once macOS freed them")
        XCTAssertFalse(retrier.isRetrying("svc"))
    }

    func testGivesUpAfterTheLastDelay() async {
        let retrier = PurgeRetrier()
        let done = expectation(description: "done")
        retrier.schedule(service: "svc", urgency: 4, delays: [0.02, 0.02], purge: { Self.result(0) }) { bytes in
            XCTAssertEqual(bytes, 0)
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 2)
        XCTAssertFalse(retrier.isRetrying("svc"), "offered again with its button")
    }

    func testOutcomeThatRemovedNothing() {
        let nothing = PurgeRun.Outcome(estimate: 91_400_000, reported: 0, freed: 300_000, error: nil, skipped: false)
        XCTAssertTrue(nothing.removedNothing, "a few hundred kilobytes are the system's own writes")
        XCTAssertEqual(PurgeRun.result(nothing, what: "assets").message, "macOS kept them for now; MacSpace keeps asking in the background.",
                       "the user is not asked to try again")
        let freed = PurgeRun.Outcome(estimate: 91_400_000, reported: 90_000_000, freed: 88_000_000, error: nil, skipped: false)
        XCTAssertEqual(PurgeRun.result(freed, what: "assets").message, "Freed \(ByteFormat.string(88_000_000)) of assets, measured on the volume.")
        let skipped = PurgeRun.Outcome(estimate: 2_000, reported: 0, freed: 0, error: nil, skipped: true)
        XCTAssertFalse(skipped.removedNothing)
        XCTAssertEqual(PurgeRun.result(skipped, what: "assets").message, "macOS has nothing to free right now.")
    }
}

final class FileTreeSizerTests: XCTestCase {
    func testAnUnreadableFolderIsCountedNotSizedAsEmpty() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sizer-\(UUID().uuidString)")
        let closed = root.appendingPathComponent("closed")
        try FileManager.default.createDirectory(at: closed, withIntermediateDirectories: true)
        try Data(count: 10_000).write(to: closed.appendingPathComponent("file"))
        try Data(count: 5_000).write(to: root.appendingPathComponent("open"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: closed.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: closed.path)
            try? FileManager.default.removeItem(at: root)
        }
        let size = try XCTUnwrap(FileTreeSizer().size(at: root))
        XCTAssertEqual(size.logicalBytes, 5_000)
        XCTAssertEqual(size.unreadableFolders, 1)
    }
}

final class CleanupHistoryTests: XCTestCase {
    func testKeepsEveryCleanupAndALifetimeTotalThatNeverShrinks() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let history = CleanupHistory(url: url)
        history.record(moduleID: "m", moduleName: "System Data", freedBytes: 408_800_000, trigger: .manual, summary: "Clean")
        history.record(moduleID: "m", moduleName: "System Data", freedBytes: 500_000, trigger: .automatic, summary: "noise")
        XCTAssertEqual(history.entries.count, 1, "less than 1 MB is not a cleanup worth listing")
        for _ in 0..<600 { history.record(moduleID: "s", moduleName: "Siri", freedBytes: 11_080_000_000, trigger: .background, summary: "models") }
        XCTAssertEqual(history.entries.count, 500, "old entries are trimmed")
        XCTAssertEqual(history.lifetimeBytes, 408_800_000 + 600 * 11_080_000_000, "trimmed entries still count")
        XCTAssertEqual(CleanupHistory(url: url).lifetimeBytes, history.lifetimeBytes, "kept across launches")
        XCTAssertEqual(history.entries.first?.moduleName, "Siri", "newest first")
    }
}
