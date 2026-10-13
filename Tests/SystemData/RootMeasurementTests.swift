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
        XCTAssertEqual(handler.operations, ["systemdata.measure", "systemdata.staged-update.delete", "systemdata.versions.delete",
                                            "systemdata.wallpaper-downloads.delete", "systemdata.unified-log.erase",
                                            "systemdata.symbolication-cache.delete"])
        XCTAssertEqual(handler.readOnlyOperations, ["systemdata.measure"], "erasing the log is an administrator's operation")
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

    /// A place named in advance that the helper finds becomes an item, taken off the item that holds it; one it does not find, or a
    /// small one, does not.
    func testHelperFoundPlacesBecomeItemsOfTheirOwn() throws {
        let rootT = "/private/var/folders/zz/rootdir/T"
        let downloads = rootT + "/com.apple.idleassetsd"
        let parent = SystemDataItem(id: "folders:other", title: "Other", kind: .systemLibrary, paths: [rootT], bytes: nil, readable: false, owners: [],
                                    inUse: false, cleanup: SystemDataCleanup(kind: .managedByMacOS, description: "d", command: nil), notes: [])
        func place(_ id: String, _ path: String) -> RootOnlyPlace {
            RootOnlyPlace(id: id, title: "Downloads", kind: .systemLibrary, path: path, cleanup: SystemDataCleanup(kind: .review, description: "why", command: nil),
                          notes: [], within: "folders:other")
        }
        var snap = snapshot(unreadable: [rootT])
        snap.report.items = [parent]
        snap.report.rootOnly = [place("found", downloads), place("missing", "/private/var/folders/zz/other/T/com.apple.idleassetsd")]
        let merged = RootMeasurements.merge([rootT: 300_000_000_000, downloads: 200_000_000_000], into: snap)
        XCTAssertEqual(merged.report.items.map(\.id), ["found", "folders:other"], "largest first")
        XCTAssertEqual(merged.report.items.first { $0.id == "found" }?.bytes, 200_000_000_000)
        XCTAssertEqual(merged.report.items.first { $0.id == "folders:other" }?.bytes, 100_000_000_000, "counted once")
        XCTAssertEqual(merged.report.measuredBytes, 300_000_000_000)
        XCTAssertTrue(merged.report.unreadable.isEmpty)
        XCTAssertEqual(RootMeasurements.merge([rootT: 1_000, downloads: 10], into: snap).report.items.map(\.id), ["folders:other"], "too small to list")
        XCTAssertTrue(RootMeasuredLocations.isAllowed(downloads), "the helper may measure it")
    }

    /// The dozens of closed folders in /private/var/folders are one place in the banner.
    func testBannerCountsTheOtherAccountsFoldersAsOnePlace() throws {
        let snap = snapshot(unreadable: [spotlight, "/private/var/folders/zz/a/C", "/private/var/folders/zz/a/T", "/private/var/folders/zz/b/T"])
        guard case let .banner(banner)? = SystemDataScreenBuilder.partialBanner(snap) else { return XCTFail() }
        XCTAssertTrue(banner.message?.hasPrefix("2 places") == true, banner.message ?? "")
    }

    func testBannerSaysWhatTheUserCanDoAboutEachPlace() throws {
        func message(_ snap: SystemDataSnapshot) -> String? {
            guard case let .banner(banner)? = SystemDataScreenBuilder.partialBanner(snap) else { return nil }
            return banner.title + " " + (banner.message ?? "")
        }
        var snap = snapshot(unreadable: [spotlight, "/Users/x/Library/Containers"])
        snap.report.fullDiskAccess = false
        let first = try XCTUnwrap(message(snap))
        XCTAssertTrue(first.contains("Full Disk Access"), "one step at a time: Full Disk Access first")

        snap.report.fullDiskAccess = true
        let withAccess = try XCTUnwrap(message(snap))
        XCTAssertTrue(withAccess.contains("Turn on the helper") && !withAccess.contains("Containers"), "with access only the helper step remains")

        snap.helperTried = true
        XCTAssertNil(message(snap), "the helper ran and macOS still keeps the place closed: nothing the user can fix, so no warning")
        XCTAssertEqual(SystemDataScreenBuilder.quietlySkipped(snap), 2)

        snap.helperError = "Couldn’t communicate with a helper application."
        let unreachable = try XCTUnwrap(message(snap))
        XCTAssertTrue(unreachable.contains("did not answer"))
    }
}
