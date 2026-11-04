import Foundation
import Darwin
import XCTest
import MacSpaceSdk
import MacSpacePlatform
import MacSpaceDiskMapPrivileged
@testable import MacSpaceDiskMap

final class DiskAppDataReviewTests: XCTestCase {
    private func fixture(_ body: (String, DiskApplication) throws -> Void) throws {
        guard getuid() != 0, geteuid() == getuid() else { throw XCTSkip("Requires ordinary user execution") }
        let home = "/private/tmp/app-data-review-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: home) }
        let path = home + "/Applications/Example.app"
        try FileManager.default.createDirectory(atPath: path + "/Contents", withIntermediateDirectories: true)
        try (["CFBundleIdentifier": "org.example.product", "CFBundleName": "Example", "CrProductDirName": "Vendor/Product"] as NSDictionary).write(to: URL(fileURLWithPath: path + "/Contents/Info.plist"))
        let owner = try XCTUnwrap(AppOwner(path: path))
        let resolver = OwnershipResolver(catalog: AppCatalog(owners: [owner]))
        for target in [home + "/Library/Application Support/Example/data", home + "/Library/Application Support/Vendor/Product/data", home + "/Library/Caches/" + owner.identifier + "/cache", home + "/Library/Preferences/" + owner.identifier + ".plist"] {
            try FileManager.default.createDirectory(atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try Data(repeating: 1, count: 8192).write(to: URL(fileURLWithPath: target))
        }
        let app = DiskApplication(owner: owner, bytes: 8192, dataPaths: [], removable: true, classification: .installedUser,
            ownership: resolver.claims(for: owner, home: home, systemLibrary: home + "/SystemLibrary"),
            plan: resolver.plan(for: owner, home: home, systemLibrary: home + "/SystemLibrary"))
        try body(home, app)
    }
    func testReviewIncludesNamedSupportAndSettingsUncheckedAndExcludesSharedData() throws {
        try fixture { home, app in
            var apps = DiskApplications(); apps.apps = [app]
            let candidates = DiskAppDataRemoval.candidates(app, apps: apps.apps, home: home)
            XCTAssertEqual(candidates.count, 4)
            XCTAssertTrue(candidates.contains { $0.fileIdentity != nil })
            let page = DiskMapScreenBuilder.uninstallReview(DiskIndex(root: home), app: app, apps: apps, home: home)
            XCTAssertEqual(page.primary?.id, "uninstall")
            XCTAssertEqual(page.selection?.choices.count, 4)
            XCTAssertTrue(page.selection?.checked.isEmpty == true)
            XCTAssertEqual(page.selection?.includedBytes, app.bytes)
            XCTAssertTrue(page.selection?.note?.contains("Selected app data") == true)
            XCTAssertEqual(app.plan?.targets.map(\.path), [app.owner.path], "Inferred paths are never silently added to the privileged plan")
            var withDataPlan = app
            let optional = try XCTUnwrap(candidates.first)
            var extra = try XCTUnwrap(app.plan?.targets.first)
            extra.path = optional.path; extra.identity = optional.identity
            extra.evidence = .init(paths: [optional.path], ownerPaths: [app.owner.path], confidence: .verifiedExclusive, source: "fixture", reason: "Fixture")
            withDataPlan.plan?.targets.append(extra)
            let encoded = try XCTUnwrap(DiskMapScreenBuilder.uninstallAction(withDataPlan)?.parameters["plan"])
            XCTAssertEqual(try JSONDecoder().decode(AppRemovalPlan.self, from: Data(encoded.utf8)).targets.map(\.path), [app.owner.path], "All associated data remains optional in the review flow")
            XCTAssertTrue(DiskAppDataRemoval.candidates(withDataPlan, apps: [withDataPlan], home: home).contains(optional))
            var other = app; other.owner.path = home + "/Applications/Copy.app"
            other.ownership = app.ownership.map { var claim = $0; claim.ownerPaths = [other.owner.path]; return claim }
            XCTAssertTrue(DiskAppDataRemoval.candidates(app, apps: [app, other], home: home).isEmpty)
        }
    }
    func testExplicitSelectionRemovesOnlyChosenDataAndPreservesBundleAndOtherData() throws {
        try fixture { home, app in
            let candidates = DiskAppDataRemoval.candidates(app, apps: [app], home: home)
            let selected = candidates.filter { $0.path.hasSuffix("/Example") || $0.fileIdentity != nil }
            let result = try DiskAppDataRemoval.remove(ids: Set(selected.map(\.id)), candidates: candidates, moveToTrash: false, home: home)
            XCTAssertTrue(result.failures.isEmpty)
            XCTAssertEqual(Set(result.removed), Set(selected.map(\.path)))
            XCTAssertTrue(FileManager.default.fileExists(atPath: app.owner.path))
            for target in candidates { XCTAssertEqual(FileManager.default.fileExists(atPath: target.path), !selected.contains(target)) }
        }
    }
    func testStaleSettingsForgedChoicesAndOpenDataRejectBeforeAnyRemoval() throws {
        try fixture { home, app in
            let candidates = DiskAppDataRemoval.candidates(app, apps: [app], home: home)
            let ids = Set(candidates.map(\.id)), preference = try XCTUnwrap(candidates.first { $0.fileIdentity != nil })
            XCTAssertThrowsError(try DiskAppDataRemoval.remove(ids: ids.union(["forged"]), candidates: candidates, moveToTrash: false, home: home))
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: preference.path))
            XCTAssertThrowsError(try DiskAppDataRemoval.remove(ids: ids, candidates: candidates, moveToTrash: false, home: home))
            try handle.close()
            try Data(repeating: 2, count: 16384).write(to: URL(fileURLWithPath: preference.path))
            XCTAssertThrowsError(try DiskAppDataRemoval.remove(ids: ids, candidates: candidates, moveToTrash: false, home: home))
            XCTAssertTrue(candidates.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
            XCTAssertNil(DiskAppDataRemoval.target(home + "/Library/Application Support", home: home))
            XCTAssertNil(DiskAppDataRemoval.target(home + "/Documents/important.plist", home: home))
        }
    }
    func testInstalledAppNamesVendorPathsIdentifiersAndUnreadableScopesAreNotUnmatched() throws {
        try fixture { home, app in
            var index = DiskIndex(root: home)
            let support = home + "/Library/Application Support"
            let paths = [support + "/Example", support + "/Vendor", support + "/org.example.product.helper", support + "/Unrelated"]
            index.directories[support] = DiskDirectory(path: support, folders: paths)
            for path in paths { index.directories[path] = DiskDirectory(path: path, bytes: 8192) }
            let leftovers = DiskApplications.unmatchedData(index, apps: [app], knownIdentifiers: [], home: home)
            XCTAssertEqual(leftovers.map(\.path), [support + "/Unrelated"])
            index.directories[support]?.readable = false
            XCTAssertTrue(DiskApplications.unmatchedData(index, apps: [app], knownIdentifiers: [], home: home).isEmpty)
        }
    }
    func testLibraryAndEmbeddedUpdaterCopiesCannotBecomeUninstallableByRegistration() throws {
        try fixture { home, app in
            for path in [home + "/Library/Application Support/Example/Updater.app", app.owner.path + "/Contents/Helpers/Updater.app"] {
                try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try FileManager.default.copyItem(atPath: app.owner.path, toPath: path.hasPrefix(app.owner.path + "/") ? home + "/copy.app" : path)
                if path.hasPrefix(app.owner.path + "/") { try FileManager.default.moveItem(atPath: home + "/copy.app", toPath: path) }
                var owner = app.owner; owner.path = path
                XCTAssertEqual(AppOwnership.classification(owner, home: home, registered: [path]).0, .extraCopy)
            }
        }
    }
    func testUUIDContainerMetadataAndHostPreferencesProtectInstalledApps() throws {
        try fixture { home, app in
            var index = DiskIndex(root: home)
            let base = home + "/Library/Containers", container = base + "/" + UUID().uuidString
            try FileManager.default.createDirectory(atPath: container, withIntermediateDirectories: true)
            try (["MCMMetadataIdentifier": app.owner.identifier] as NSDictionary).write(to: URL(fileURLWithPath: container + "/.com.apple.containermanagerd.metadata.plist"))
            index.directories[base] = DiskDirectory(path: base, folders: [container])
            index.directories[container] = DiskDirectory(path: container, bytes: 8192)
            let byHost = home + "/Library/Preferences/ByHost"
            try FileManager.default.createDirectory(atPath: byHost, withIntermediateDirectories: true)
            let installed = byHost + "/" + app.owner.identifier + "." + UUID().uuidString + ".plist"
            let unmatched = byHost + "/org.unmatched.fixture." + UUID().uuidString + ".plist"
            for path in [installed, unmatched] { try Data(repeating: 1, count: 8192).write(to: URL(fileURLWithPath: path)) }
            let resolver = OwnershipResolver(catalog: AppCatalog(owners: [app.owner]), byHostPreferences: [installed, unmatched])
            XCTAssertTrue(resolver.claims(for: app.owner, home: home, systemLibrary: home + "/SystemLibrary").flatMap(\.paths).contains(installed))
            let leftovers = DiskApplications.unmatchedData(index, apps: [app], knownIdentifiers: [], home: home)
            XCTAssertEqual(leftovers.map(\.path), [unmatched])
            XCTAssertNotNil(leftovers.first?.fileIdentity)
            let result = try XCTUnwrap(DiskUnmatchedRemoval.execute(ids: Set(leftovers.map(\.choiceID)), candidates: leftovers, home: home))
            XCTAssertTrue(result.failures.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: unmatched))
            XCTAssertTrue(FileManager.default.fileExists(atPath: installed))
            XCTAssertTrue(FileManager.default.fileExists(atPath: container))
        }
    }
    func testInstalledVendorProtectsSharedSupportRootAndSiblingHelperData() throws {
        try fixture { home, app in
            var installed = app; installed.owner.identifier = "com.vendor.product"; installed.owner.identifiers = [installed.owner.identifier]
            let base = home + "/Library/Application Support"
            let paths = [base + "/Vendor", base + "/com.vendor.sharedhelper", base + "/Unrelated"]
            var index = DiskIndex(root: home)
            index.directories[base] = DiskDirectory(path: base, folders: paths)
            for path in paths { index.directories[path] = DiskDirectory(path: path, bytes: 8192) }
            let rows = DiskApplications.unmatchedData(index, apps: [installed], knownIdentifiers: [], home: home)
            XCTAssertEqual(rows.map(\.path), [base + "/Unrelated"])
        }
    }
    func testIndexedComponentNamesSystemServicesAndVersionedDataAreNotUnmatched() throws {
        try fixture { home, app in
            let base = home + "/Library/Application Support"
            let paths = ["Codex", "CloudKit", "NetworkServiceProxy", "SketchUp 2027", "Unrelated"].map { base + "/" + $0 }
            var index = DiskIndex(root: home)
            index.directories[base] = DiskDirectory(path: base, folders: paths)
            for path in paths { index.directories[path] = DiskDirectory(path: path, bytes: 8192) }
            let known: Set<String> = ["com.openai.codex", "com.apple.CloudKit", "com.apple.NetworkServiceProxyFramework", "com.sketchup.SketchUp.2027"]
            XCTAssertEqual(DiskApplications.unmatchedData(index, apps: [app], knownIdentifiers: known, home: home).map(\.path), [base + "/Unrelated"])
        }
    }
    func testContainingAppCanReviewRelatedEmbeddedComponentDataWithoutClaimingSystemFrameworkData() throws {
        try fixture { home, app in
            let component = app.owner.path + "/Contents/Helpers/Engine.app/Contents"
            try FileManager.default.createDirectory(atPath: component, withIntermediateDirectories: true)
            try (["CFBundleIdentifier": "org.example.engine"] as NSDictionary).write(to: URL(fileURLWithPath: component + "/Info.plist"))
            let data = home + "/Library/Application Support/Engine"
            try FileManager.default.createDirectory(atPath: data, withIntermediateDirectories: true)
            try Data([1]).write(to: URL(fileURLWithPath: data + "/payload"))
            let db = try DiskDatabase(url: URL(fileURLWithPath: home + "/cache/index.sqlite"), root: home, home: home)
            var scanner = DiskDatabaseScanner(db: db, excluded: [home + "/cache"])
            try scanner.scan(.init(), cursor: 1, progress: nil)
            let index = try db.snapshot().index
            XCTAssertTrue(index.appBundleIdentifiers?[app.owner.path]?.contains("org.example.engine") == true)
            let resolver = OwnershipResolver(catalog: AppCatalog(owners: [app.owner]),
                embeddedIdentifiers: [app.owner.path: ["org.example.engine", "com.apple.CloudKit"]], availableDataPaths: [data])
            let claims = resolver.claims(for: app.owner, home: home, systemLibrary: home + "/SystemLibrary")
            XCTAssertTrue(claims.contains { $0.paths.contains(data) && $0.confidence == .inferred })
            XCTAssertFalse(claims.flatMap(\.paths).contains { $0.hasSuffix("/CloudKit") })
        }
    }
}
