import Foundation
import Darwin
import XCTest
import MacSpaceSdk
import MacSpaceDiskMapPrivileged
@testable import MacSpaceDiskMap

final class DiskLiveNavigationTests: XCTestCase {
    func testReadOnlyCachedNavigationAndOwnershipCost() throws {
        guard ProcessInfo.processInfo.environment["MACSPACE_DISK_LIVE_BENCH"] == "1" else { throw XCTSkip("Opt-in read-only startup cache benchmark") }
        let cache = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/com.macspace.disk-map/Index-v2.scan")
        let started = Date()
        let snapshot = DiskSnapshot(try DiskCache.read(from: cache, root: "/"))
        let load = Date().timeIntervalSince(started)
        let inventoryStart = Date(), apps = DiskApplications.read(snapshot.index, previous: nil)
        let inventoryTime = Date().timeIntervalSince(inventoryStart)
        let folders = snapshot.index.directories.values.filter { !$0.folders.isEmpty && !$0.path.contains(".app/") }.prefix(100).map(\.path)
        let pageStart = Date()
        for path in folders {
            let page = DiskMapScreenBuilder.screen(snapshot.index, apps: DiskApplications(), folder: path, files: snapshot.files)
            XCTAssertNotNil(page.hero)
        }
        let pageTime = Date().timeIntervalSince(pageStart)
        let ownershipStart = Date()
        var attributed = snapshot.index
        attributed.ownershipClaims = DiskOwnership.assign(to: &attributed, catalog: apps)
        let ownershipTime = Date().timeIntervalSince(ownershipStart)
        let count = apps.apps.filter { $0.classification == .installedUser }.count
        var info = rusage_info_v6()
        _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V6, $0) } }
        print("DISK_LIVE_NAVIGATION directories=\(snapshot.index.directories.count) files=\(snapshot.files.count) cacheLoadSeconds=\(load) inventorySeconds=\(inventoryTime) installedUserApps=\(count) otherCopies=\(apps.apps.count-count) pages=\(folders.count) pageBuildSeconds=\(pageTime) ownershipSeconds=\(ownershipTime) claims=\(attributed.ownershipClaims?.count ?? 0) retainedIndexFootprintMiB=\(Double(info.ri_phys_footprint)/1_048_576)")
        XCTAssertLessThan(pageTime, 2, "Building 100 cached folder pages must not reconcile or serialize the index")
        withExtendedLifetime(attributed) {}
    }
}
