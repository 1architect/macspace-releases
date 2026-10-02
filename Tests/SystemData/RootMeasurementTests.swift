import XCTest
import MacSpacePlatform
import MacSpaceSdk
@testable import MacSpaceSystemData
@testable import MacSpaceSystemDataPrivileged

final class RootMeasurementTests: XCTestCase {
    private let spotlight = "/System/Volumes/Data/.Spotlight-V100"

    private func snapshot(unreadable: [String], itemBytes: UInt64? = nil) -> SystemDataSnapshot {
        let item = SystemDataItem(id: "index:spotlight", title: "Spotlight index", kind: .spotlightIndex, paths: [spotlight], bytes: itemBytes, readable: itemBytes != nil,
                                  owners: [], inUse: false, cleanup: SystemDataCleanup(kind: .managedByMacOS, description: "d", command: nil), notes: [])
        return SystemDataSnapshot(
            report: SystemDataReport(schemaVersion: 1, generatedAt: Date(), volumes: [], items: [item], measuredBytes: 0, cleanableBytes: 0, manualCleanup: [],
                                     unreadable: unreadable, warnings: ["x"]),
            purgeableAssetsBytes: nil, reports: CleanupPlan(olderThanDays: 7, cutoff: .distantPast, candidates: [], totalBytes: 0, unreadableDirectories: []), takenAt: Date())
    }

    func testHelperOperationSizesOnlyKnownLocations() throws {
        let handler = SystemDataPrivilegedOperations()
        XCTAssertEqual(handler.operations, ["systemdata.measure", "systemdata.staged-update.delete", "systemdata.versions.delete"])
        let data = try handler.handle("systemdata.measure", arguments: ["paths": "/etc\n/Users\n/nonexistent"], caller: PrivilegedCaller(uid: 501))
        XCTAssertEqual(try JSONDecoder().decode(RootMeasurementResponse.self, from: data).sizes, [:], "paths outside the fixed list are never sized")
        XCTAssertThrowsError(try handler.handle("other", arguments: [:], caller: PrivilegedCaller(uid: 501)))
    }

    func testMeasuredSizesReplaceTheUnreadableEntries() {
        let merged = RootMeasurements.merge([spotlight: 3_000_000_000], into: snapshot(unreadable: [spotlight, "/System/Library/Caches/com.apple.coresymbolicationd"]))
        XCTAssertEqual(merged.report.items.first?.bytes, 3_000_000_000)
        XCTAssertEqual(merged.report.unreadable, ["/System/Library/Caches/com.apple.coresymbolicationd"])
        XCTAssertEqual(merged.report.measuredBytes, 3_000_000_000)
    }

    func testBannerSaysWhatTheUserCanDoAboutEachPlace() throws {
        func message(_ snap: SystemDataSnapshot) -> String? {
            guard case let .banner(banner)? = SystemDataScreenBuilder.partialBanner(snap) else { return nil }
            return banner.message
        }
        var snap = snapshot(unreadable: [spotlight, "/Users/x/Library/Containers"])
        snap.report.fullDiskAccess = false
        let first = try XCTUnwrap(message(snap))
        XCTAssertTrue(first.contains("Turn on the helper") && first.contains("needs Full Disk Access"))

        snap.report.fullDiskAccess = true
        let withAccess = try XCTUnwrap(message(snap))
        XCTAssertTrue(withAccess.contains("Turn on the helper") && !withAccess.contains("Containers"), "with access only the helper step remains")

        snap.helperTried = true
        XCTAssertNil(message(snap), "the helper ran and macOS still keeps the place closed: nothing the user can fix, so no warning")
        XCTAssertEqual(SystemDataScreenBuilder.quietlySkipped(snap), 2)

        snap.helperError = "Couldn’t communicate with a helper application."
        let unreachable = try XCTUnwrap(message(snap))
        XCTAssertTrue(unreachable.contains("could not be reached"))
    }
}
