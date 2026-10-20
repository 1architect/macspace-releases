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
        XCTAssertEqual(PurgeRun.result(nothing, what: "assets").message, "Finishing in the background",
                       "the user is not asked to try again")
        let freed = PurgeRun.Outcome(estimate: 91_400_000, reported: 90_000_000, freed: 88_000_000, error: nil, skipped: false)
        XCTAssertEqual(PurgeRun.result(freed, what: "assets").message, "Freed \(ByteFormat.string(88_000_000))")
        let skipped = PurgeRun.Outcome(estimate: 2_000, reported: 0, freed: 0, error: nil, skipped: true)
        XCTAssertFalse(skipped.removedNothing)
        XCTAssertEqual(PurgeRun.result(skipped, what: "assets").message, "Nothing to free")
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

    /// A file reached by two hard links is stored once, and counted once: in one tree, across trees that share a ledger, and by
    /// Settings' category sizes (`AllocatedSize`). Counted per path, Spotlight's own store came to 1.49 GB more than it takes.
    func testAHardLinkedFileIsCountedOnce() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("links-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("a"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("b"), withIntermediateDirectories: true)
        let file = root.appendingPathComponent("a/blob")
        try Data(count: 1_000_000).write(to: file)
        try FileManager.default.linkItem(at: file, to: root.appendingPathComponent("a/again"))
        try FileManager.default.linkItem(at: file, to: root.appendingPathComponent("b/blob"))
        XCTAssertEqual(try XCTUnwrap(FileTreeSizer().size(at: root)).logicalBytes, 1_000_000)
        let ledger = CloneLedger()
        let first = try XCTUnwrap(FileTreeSizer(clones: ledger).size(at: root.appendingPathComponent("a"))).logicalBytes
        let second = try XCTUnwrap(FileTreeSizer(clones: ledger).size(at: root.appendingPathComponent("b"))).logicalBytes
        XCTAssertEqual(first + second, 1_000_000)
        XCTAssertLessThan(AllocatedSize.allocatedBytes(root.path, excluding: []), 1_200_000)
    }

    /// Walked by several threads (`ScanPool`), a tree adds up to what one thread finds; links are not followed, and an excluded
    /// folder is left out of Settings' category sizes.
    func testATreeWalkedBySeveralThreadsAddsUpTheSame() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("walk-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for folder in 0..<12 {
            for depth in 0..<3 {
                let directory = root.appendingPathComponent("f\(folder)/" + Array(repeating: "d", count: depth + 1).joined(separator: "/"))
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                for file in 0..<5 { try Data(count: 1_000 * (folder + 1) + file).write(to: directory.appendingPathComponent("file\(file)")) }
            }
        }
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("walk-outside-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data(count: 9_000_000).write(to: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
        // Each folder: three levels of five files of 1,000 × (folder + 1) bytes, plus 0 + 1 + 2 + 3 + 4.
        var expected: UInt64 = 0
        for folder in 0..<12 { expected += UInt64(3 * (5_000 * (folder + 1) + 10)) }

        let alone = try XCTUnwrap(FileTreeSizer(countsPurgeable: true).size(at: root))
        let together = try XCTUnwrap(FileTreeSizer(countsPurgeable: true, pool: ScanPool(free: 4)).size(at: root))
        XCTAssertEqual(alone.logicalBytes, expected, "the link's 9 MB are not followed")
        XCTAssertEqual(together, alone)
        let all = AllocatedSize.allocatedBytes(root.path, excluding: [])
        XCTAssertEqual(AllocatedSize.allocatedBytes([(root.path, []), (root.path, [root.appendingPathComponent("f11").path])], workers: 2).first, all)
        XCTAssertLessThan(AllocatedSize.allocatedBytes(root.path, excluding: [root.appendingPathComponent("f11").path]), all)
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
        XCTAssertEqual(history.entries.count, 100, "old entries are trimmed")
        XCTAssertEqual(history.lifetimeBytes, 408_800_000 + 600 * 11_080_000_000, "trimmed entries still count")
        XCTAssertEqual(CleanupHistory(url: url).lifetimeBytes, history.lifetimeBytes, "kept across launches")
        XCTAssertEqual(history.entries.first?.moduleName, "Siri", "newest first")
    }

    func testAHistoryKeptBeforeTheLimitIsTrimmedWhenRead() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        // As a build before the limit saved it: every entry, nothing trimmed yet.
        struct Saved: Encodable { let entries: [CleanupHistory.Entry]; let trimmedBytes: UInt64 }
        let entries = (0..<263).map { CleanupHistory.Entry(moduleID: "m", moduleName: "Caches \($0)", freedBytes: 2_000_000, trigger: .manual, summary: "") }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(Saved(entries: entries, trimmedBytes: 0)).write(to: url)
        let history = CleanupHistory(url: url)
        XCTAssertEqual(history.entries.count, 100)
        XCTAssertEqual(history.entries.first?.moduleName, "Caches 262", "the newest are kept")
        XCTAssertEqual(history.lifetimeBytes, 263 * 2_000_000, "the dropped ones still count")
        XCTAssertEqual(CleanupHistory(url: url).entries.count, 100, "saved trimmed")
    }
}

final class PurgeHoldoutsTests: XCTestCase {
    private let service = "com.apple.mobileassetd.cache-delete"

    func testWithoutAHoldTheWholeEstimateCounts() {
        XCTAssertEqual(PurgeHoldouts(url: nil).freeable(service, estimate: 129_103_785), 129_103_785)
    }

    func testWhatMacOSKeptIsNotOfferedWhileItEstimatesTheSame() {
        let holdouts = PurgeHoldouts(url: nil)
        holdouts.hold(service, bytes: 129_103_785)
        XCTAssertEqual(holdouts.freeable(service, estimate: 129_103_785), 0)
        XCTAssertEqual(holdouts.freeable(service, estimate: 131_000_000), 0, "measured again, the same files")
    }

    func testOnlyWhatComesOnTopCounts() {
        let holdouts = PurgeHoldouts(url: nil)
        holdouts.hold(service, bytes: 129_103_785)
        XCTAssertEqual(holdouts.freeable(service, estimate: 11_129_103_785), 11_000_000_000, "released models on top of the kept assets")
    }

    func testTheHoldGoesWhenTheEstimateDropsOrADayPasses() {
        let holdouts = PurgeHoldouts(url: nil)
        let start = Date(timeIntervalSince1970: 0)
        holdouts.hold(service, bytes: 129_103_785, now: start)
        XCTAssertEqual(holdouts.freeable(service, estimate: 50_000_000, now: start), 50_000_000)
        XCTAssertEqual(holdouts.freeable(service, estimate: 129_103_785, now: start), 129_103_785, "dropped, so the hold is gone")
        holdouts.hold(service, bytes: 129_103_785, now: start)
        XCTAssertEqual(holdouts.freeable(service, estimate: 129_103_785, now: start.addingTimeInterval(PurgeHoldouts.lifetime)), 129_103_785)
    }

    func testHoldsSurviveARelaunch() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("holdouts-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        PurgeHoldouts(url: url).hold(service, bytes: 129_103_785)
        XCTAssertEqual(PurgeHoldouts(url: url).freeable(service, estimate: 129_103_785), 0)
    }
}
