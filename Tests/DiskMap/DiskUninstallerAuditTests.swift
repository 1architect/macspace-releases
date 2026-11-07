import Foundation
import XCTest
import MacSpaceDiskMapPrivileged
@testable import MacSpaceDiskMap

/// Read-only catalog audit using an isolated index backup; never executes an uninstall or opens an app.
final class DiskUninstallerAuditTests: DiskSecurityFixtureCase {
    func testLocalUninstallerAndUnmatchedDataAudit() throws {
        guard let source = ProcessInfo.processInfo.environment["MACSPACE_UNINSTALLER_AUDIT_CACHE"] else {
            throw XCTSkip("Set MACSPACE_UNINSTALLER_AUDIT_CACHE to an isolated SQLite backup")
        }
        let db = try DiskDatabase(url: URL(fileURLWithPath: source), root: "/")
        let index = try db.snapshot().index
        let started = Date(), apps = DiskApplications.read(index, previous: nil)
        let inventorySeconds = Date().timeIntervalSince(started)
        let installed = apps.apps.filter { $0.classification == .installedUser }
        let counts = installed.map { ($0.owner.name, DiskAppDataRemoval.candidates($0, apps: apps.apps).count) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let claimed = apps.apps.flatMap(\.ownership).flatMap(\.paths)
        for item in apps.reviewableLeftovers {
            XCTAssertFalse(claimed.contains { item.path == $0 || item.path.hasPrefix($0 + "/") || $0.hasPrefix(item.path + "/") })
            XCTAssertFalse(item.identifier.lowercased().contains("com.apple."))
        }
        XCTAssertTrue(installed.allSatisfy { !$0.owner.path.hasPrefix(home + "/Library/") && !$0.owner.path.contains(".app/") })
        let destination = ProcessInfo.processInfo.environment["MACSPACE_UNINSTALLER_AUDIT_REPORT"] ?? "/tmp/macspace-uninstaller-audit.md"
        let hiddenUpdaters = apps.apps.filter { $0.owner.name.lowercased().contains("updater") && $0.classification != .installedUser }
        let report = """
        # Uninstaller and unmatched app-data audit

        Read-only backend audit on 2026-11-04. No apps were opened or removed, and no app data was modified.

        - Catalog entries: \(apps.apps.count)
        - Standalone installed apps shown: \(installed.count)
        - System/background/extra copies hidden: \(apps.apps.count - installed.count)
        - Hidden updater copies: \(hiddenUpdaters.count)
        - Apps with optional associated data available for review: \(counts.filter { $0.1 > 0 }.count)
        - Optional app/data associations: \(counts.reduce(0) { $0 + $1.1 })
        - Unmatched data locations: \(apps.reviewableLeftovers.count)
        - Selectable unmatched locations: \(apps.reviewableLeftovers.filter { $0.identity != nil }.count)
        - Audit duration: \(String(format: "%.2f", Date().timeIntervalSince(started))) seconds
        - App inventory preparation: \(String(format: "%.2f", inventorySeconds)) seconds

        ## Optional data by app

        \(counts.filter { $0.1 > 0 }.map { "- \($0.0): \($0.1) locations" }.joined(separator: "\n"))

        ## Hidden updater examples

        \(hiddenUpdaters.prefix(10).map { "- " + $0.owner.path }.joined(separator: "\n"))

        ## Unmatched locations for manual review

        \(apps.reviewableLeftovers.map { "- " + $0.path }.joined(separator: "\n"))

        ## Review limits

        Associations based on names, identifiers and vendor metadata are suggestions, not proof of exclusive ownership. They are never preselected. Known shared claims, overlapping claims from other installations, receipts, helpers, system-managed stores and paths outside supported user Library locations are excluded from optional removal. A missing app match does not prove that data is abandoned. Discovery outside indexed and registered locations can be incomplete.
        """
        try report.write(toFile: destination, atomically: true, encoding: .utf8)
        print("UNINSTALLER_AUDIT installed=\(installed.count) hidden=\(apps.apps.count - installed.count) optionalAssociations=\(counts.reduce(0) { $0 + $1.1 }) unmatched=\(apps.reviewableLeftovers.count) seconds=\(Date().timeIntervalSince(started))")
    }
}
