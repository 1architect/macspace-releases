import Foundation
import XCTest
import MacSpaceSdk
import MacSpacePlatform
@testable import MacSpaceSystemData

/// Targeted stage profiling, separate from the five-module comparison so it cannot warm that benchmark's inputs.
final class SystemDataLoadingDiagnostic: XCTestCase {
    func testReadOnlySnapshotStages() async throws {
        guard ProcessInfo.processInfo.environment["MACSPACE_SYSTEM_DATA_DIAGNOSTIC"] == "1" else {
            throw XCTSkip("Opt-in raw reader: MACSPACE_SYSTEM_DATA_DIAGNOSTIC=1")
        }
        guard LivePermissionChecker.probeFullDiskAccess() == .granted else { throw XCTSkip("Full Disk Access required") }
        let start = Date()
        let snapshot = await Task.detached(priority: .utility) { SystemDataStore.liveSnapshot(progress: LoadProgressRelay()) }.value
        XCTAssertFalse(snapshot.report.items.isEmpty)
        print("SYSTEM_DATA_SNAPSHOT seconds=\(Date().timeIntervalSince(start)) items=\(snapshot.report.items.count)")
    }
}
