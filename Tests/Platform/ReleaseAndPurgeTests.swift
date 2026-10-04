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

final class PurgeLedgerTests: XCTestCase {
    private let suite = "PurgeLedgerTests-\(UUID().uuidString)"

    override func tearDown() { UserDefaults().removePersistentDomain(forName: suite) }

    func testWhatMacOSDeclinedIsNotOfferedUntilItsEstimateGrows() {
        let ledger = PurgeLedger(suite: suite)
        XCTAssertEqual(ledger.offerable("svc", estimate: 91_400_000), 91_400_000)
        ledger.noteDeclined("svc", estimate: 91_400_000)
        XCTAssertEqual(ledger.offerable("svc", estimate: 91_400_000), 0, "no button promises what macOS just refused")
        XCTAssertEqual(ledger.offerable("svc", estimate: 105_000_000), 0, "a little more is the same files")
        XCTAssertEqual(ledger.offerable("svc", estimate: 400_000_000), 400_000_000, "much more is offered again")
        ledger.clear("svc")
        XCTAssertEqual(ledger.offerable("svc", estimate: 91_400_000), 91_400_000)
        XCTAssertNil(ledger.offerable("svc", estimate: nil))
    }

    func testOutcomeThatRemovedNothing() {
        let nothing = PurgeRun.Outcome(estimate: 91_400_000, reported: 0, freed: 300_000, error: nil, skipped: false)
        XCTAssertTrue(nothing.removedNothing, "a few hundred kilobytes are the system's own writes")
        XCTAssertEqual(PurgeRun.result(nothing, what: "assets").outcome, .needsAttention)
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
