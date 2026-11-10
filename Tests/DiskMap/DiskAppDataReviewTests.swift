import Foundation
import Darwin
import XCTest
import MacSpaceSdk
import MacSpacePlatform
import MacSpaceDiskMapPrivileged
@testable import MacSpaceDiskMap

final class DiskAppDataReviewTests: DiskSecurityFixtureCase {
    func testDefaultsDoNotSelectNamedVendorCachesSharedDataOrUserDocuments() throws {
        try fixture { home, app in
            let cache = home + "/Library/Caches/" + app.owner.identifier
            let vendor = home + "/Library/Caches/Vendor"
            try FileManager.default.createDirectory(atPath: vendor, withIntermediateDirectories: true)
            try Data([1]).write(to: URL(fileURLWithPath: vendor + "/data"))
            var selected = app
            selected.ownership.append(.init(paths: [vendor], ownerPaths: [app.owner.path], confidence: .inferred, source: "displayNameConvention", reason: "Inferred"))
            XCTAssertFalse(DiskUninstallReview.disposableCache(vendor, app: selected, home: home))
            XCTAssertFalse(DiskUninstallReview.disposableCache(home + "/Library/Application Support/Example", app: selected, home: home))
            var other = app
            other.owner.path = home + "/Applications/Other.app"
            other.ownership = [.init(paths: [cache], ownerPaths: [other.owner.path], confidence: .inferred, source: "identifierConvention", reason: "Competing installation")]
            var apps = DiskApplications(); apps.apps = [selected, other]
            var index = DiskIndex(root: home)
            index.directories[cache] = DiskDirectory(path: cache, bytes: 8192)
            let page = DiskMapScreenBuilder.uninstallReview(index, app: selected, apps: apps, home: home)
            XCTAssertTrue(page.selection?.checked.isEmpty == true)
            let selectedData = Set(page.selection?.checked ?? []).subtracting([app.owner.path])
            XCTAssertTrue(selectedData.isEmpty)
        }
    }
    func testReadonlyCategoryProvidesPreservationReasonAndKeepsItsCompleteDetailInventory() throws {
        try fixture { home, original in
            let external = home + "/SystemLibrary/Vendor"
            try FileManager.default.createDirectory(atPath: external, withIntermediateDirectories: true)
            try Data([1]).write(to: URL(fileURLWithPath: external + "/data"))
            var app = original
            app.ownership.append(.init(paths: [external], ownerPaths: [app.owner.path], confidence: .unknown, source: "fixture", reason: "Preserved"))
            var apps = DiskApplications(); apps.apps = [app]
            var index = DiskIndex(root: home)
            index.directories[external] = DiskDirectory(path: external, bytes: 6_000_000)
            let page = DiskMapScreenBuilder.uninstallReview(index, app: app, apps: apps, home: home)
            let rows = page.widgets.flatMap { if case let .list(list) = $0 { return list.rows }; return [] }
            let other = try XCTUnwrap(rows.first { $0.title == "Other app data" })
            XCTAssertNotNil(other.selectionSectionID)
            let section = try XCTUnwrap(page.selection?.sections.first { $0.id == other.selectionSectionID })
            XCTAssertEqual(section.unavailableReason, "Outside your user Library")
            XCTAssertEqual(section.rows, other.children.map(\.id))
            XCTAssertEqual(other.children.flatMap(\.paths), [external])
            XCTAssertTrue(other.children.allSatisfy { page.selection?.choices[$0.id] == nil })
            XCTAssertEqual(DiskUninstallReview.Category.of("/Library/Application Support/Autodesk", home: home), .support)
        }
    }

    func testSharedOnlyAndMixedCategoriesDistinguishPreservedAndRemovableData() throws {
        try fixture { home, original in
            var app = original
            app.ownership = original.ownership.filter { claim in
                claim.source == "bundle" || claim.paths.contains { $0.hasPrefix(home + "/Library/Application Support/") }
            }.map { claim in
                var claim = claim
                if claim.source != "bundle" {
                    claim.confidence = .shared
                    claim.ownerPaths.append(home + "/Applications/Other.app")
                }
                return claim
            }
            var apps = DiskApplications(); apps.apps = [app]
            var index = DiskIndex(root: home)
            for path in app.ownership.filter({ $0.source != "bundle" }).flatMap(\.paths) {
                index.directories[path] = DiskDirectory(path: path, bytes: 8192)
            }
            let shared = DiskMapScreenBuilder.uninstallReview(index, app: app, apps: apps, home: home)
            let categoryID = DiskUninstallReview.categoryID(app.owner.path, .support)
            let headingID = DiskUninstallReview.dataSectionID(app.owner.path)
            XCTAssertEqual(shared.selection?.sections.first { $0.id == categoryID }?.unavailableReason, "Used by other apps")
            XCTAssertEqual(shared.selection?.sections.first { $0.id == headingID }?.unavailableReason, "Used by other apps")
            XCTAssertTrue(shared.selection?.choices.isEmpty == true)
            XCTAssertEqual(shared.selection?.includedBytes, app.bytes)
            let sharedRows = shared.widgets.flatMap { if case let .list(list) = $0 { return list.rows.flatMap(\.children) }; return [] }
            XCTAssertTrue(sharedRows.allSatisfy { $0.unavailableReason == "Used by other apps" })

            let path = home + "/Library/Application Support/Exclusive"
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            try Data([1]).write(to: URL(fileURLWithPath: path + "/data"))
            app.ownership.append(.init(paths: [path], ownerPaths: [app.owner.path], confidence: .inferred, source: "fixture", reason: "App association"))
            apps.apps = [app]
            let mixed = DiskMapScreenBuilder.uninstallReview(index, app: app, apps: apps, home: home)
            XCTAssertNil(mixed.selection?.sections.first { $0.id == categoryID }?.unavailableReason)
            XCTAssertNil(mixed.selection?.sections.first { $0.id == headingID }?.unavailableReason)
            XCTAssertEqual(mixed.selection?.choices.count, 1)
            let lists = mixed.widgets.compactMap { if case let .list(list) = $0 { return list }; return nil }
            XCTAssertEqual(lists.count, 1)
            XCTAssertEqual(lists[0].headingChoice, headingID)
            XCTAssertEqual(lists[0].rows.count, 1)
            XCTAssertEqual(lists[0].rows[0].children.count, sharedRows.count + 1)
        }
    }

    func testPreparedPublisherFolderClaimsAreFilteredButExplicitSupportLinksRemain() throws {
        try fixture { home, original in
            let path = home + "/Library/Application Support/Apple"
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            try Data([1]).write(to: URL(fileURLWithPath: path + "/data"))
            var app = original
            app.ownership = [.init(paths: [path], ownerPaths: [app.owner.path, "/Applications/Other.app"], confidence: .shared,
                                  source: "displayNameConvention", reason: "Old broad name match")]
            var index = DiskIndex(root: home)
            index.directories[path] = DiskDirectory(path: path, bytes: 6_000_000)
            var apps = DiskApplications(); apps.apps = [app]
            let page = DiskMapScreenBuilder.uninstallReview(index, app: app, apps: apps, home: home)
            let lists = page.widgets.compactMap { if case let .list(list) = $0 { return list }; return nil }
            XCTAssertEqual(lists.count, 1)
            XCTAssertTrue(lists[0].rows.isEmpty)
            XCTAssertEqual(lists[0].emptyMessage, "No app data to remove")
            XCTAssertTrue(page.selection?.choices.isEmpty == true)

            app.ownership.append(.init(paths: [path], ownerPaths: [app.owner.path, "/Applications/Other.app"], confidence: .shared,
                                       source: "declaredSupportPath", reason: "Explicit app metadata"))
            apps.apps = [app]
            let explicit = DiskMapScreenBuilder.uninstallReview(index, app: app, apps: apps, home: home)
            let rows = explicit.widgets.flatMap { if case let .list(list) = $0 { return list.rows.flatMap(\.children) }; return [] }
            XCTAssertEqual(rows.flatMap(\.paths), [path])
            XCTAssertTrue(explicit.selection?.choices.isEmpty == true)
        }
    }

    func testLiveEmptyDataIsOmittedEvenWhenTheSnapshotHasAnOldSizeAndUnmatchedRowsHaveNoPills() throws {
        try fixture { home, app in
            let cache = home + "/Library/Caches/" + app.owner.identifier
            let preference = home + "/Library/Preferences/" + app.owner.identifier + ".plist"
            try FileManager.default.removeItem(atPath: cache + "/cache")
            try Data().write(to: URL(fileURLWithPath: preference))
            var index = DiskIndex(root: home)
            index.directories[cache] = DiskDirectory(path: cache, bytes: 8192)
            index.measuredOwnershipBytes = [preference: 8192]
            var apps = DiskApplications(); apps.apps = [app]
            let page = DiskMapScreenBuilder.uninstallReview(index, app: app, apps: apps, home: home)
            let children = page.widgets.flatMap { if case let .list(list) = $0 { return list.rows.flatMap(\.children) }; return [] }
            XCTAssertFalse(children.flatMap(\.paths).contains(cache))
            XCTAssertFalse(children.flatMap(\.paths).contains(preference))
            let path = home + "/Library/Application Support/Example"
            apps.reviewableLeftovers = [.init(identifier: "Empty", path: cache, bytes: 0), .init(identifier: "Example", path: path, bytes: 8192, identity: AppFileIdentity(path: path))]
            let unmatched = DiskMapScreenBuilder.leftoversPage(apps)
            let rows = unmatched.widgets.flatMap { if case let .list(list) = $0 { return list.rows }; return [] }
            XCTAssertEqual(rows.map(\.title), ["Example"])
            XCTAssertTrue(rows.allSatisfy { $0.badges.isEmpty })
            XCTAssertEqual(unmatched.selection?.choices.count, 1)
        }
    }
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
            XCTAssertNil(page.primary)
            XCTAssertEqual(page.selection?.action.id, "uninstallSelected")
            XCTAssertEqual(page.selection?.choices.count, 4)
            let cache = try XCTUnwrap(candidates.first { $0.path.hasPrefix(home + "/Library/Caches/") })
            XCTAssertEqual(Set(page.selection?.checked ?? []), [cache.id])
            XCTAssertEqual(app.ownership.first { $0.paths.contains(cache.path) }?.confidence, .inferred,
                           "Defaults must work with the ordinary scanner output, without fabricated exclusive confidence")
            XCTAssertNil(page.selection?.choices[app.owner.path])
            XCTAssertEqual(page.selection?.includedBytes, app.bytes)
            XCTAssertNil(page.selection?.note)
            XCTAssertEqual(page.selection?.action.confirmation?.title, "Uninstall selected apps?")
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
    func testOnlyVerifiedDisposableCachesAreSuggestedAndZeroByteDataIsOmitted() throws {
        try fixture { home, original in
            var app = original
            for n in app.ownership.indices {
                // Verified support/settings are still user data and must stay unchecked.
                app.ownership[n].confidence = .verifiedExclusive
            }
            let empty = home + "/Library/Caches/empty.fixture"
            try FileManager.default.createDirectory(atPath: empty, withIntermediateDirectories: true)
            app.ownership.append(.init(paths: [empty], ownerPaths: [app.owner.path], confidence: .verifiedExclusive, source: "fixture", reason: "Fixture"))
            var apps = DiskApplications(); apps.apps = [app]
            let candidates = DiskAppDataRemoval.candidates(app, apps: [app], home: home)
            let cache = try XCTUnwrap(candidates.first { $0.path.hasPrefix(home + "/Library/Caches/") && $0.path != empty })
            let page = DiskMapScreenBuilder.uninstallReview(DiskIndex(root: home), app: app, apps: apps, home: home)
            XCTAssertEqual(Set(page.selection?.checked ?? []), [cache.id])
            XCTAssertNil(page.selection?.choices[candidates.first { $0.path == empty }!.id])
            let rows = page.widgets.flatMap { if case let .list(list) = $0 { return list.rows }; return [] }
            XCTAssertFalse(rows.flatMap(\.children).contains { $0.paths.contains(empty) })
            XCTAssertTrue(page.selection?.parents.isEmpty == true)
            let effective = page.selection?.effectiveIDs(Set(page.selection?.checked ?? []).subtracting([app.owner.path]))
            XCTAssertEqual(effective, [cache.id])
            let categories = Set(rows.filter { !$0.children.isEmpty }.map(\.title))
            XCTAssertEqual(categories, ["Caches", "Application support", "Preferences"])
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
    func testNormalQuitCanWriteInsideTheSameReviewedCacheButCannotReplaceItsRootOrSettings() throws {
        try fixture { home, app in
            let candidates = DiskAppDataRemoval.candidates(app, apps: [app], home: home)
            let cache = try XCTUnwrap(candidates.first { $0.path.hasPrefix(home + "/Library/Caches/") })
            try Data([1, 2, 3]).write(to: URL(fileURLWithPath: cache.path + "/written-on-quit"))
            let refreshed = try DiskAppDataRemoval.refreshedAfterQuitting([cache], home: home)
            XCTAssertEqual(refreshed[0].identity.inode, cache.identity.inode)
            XCTAssertEqual(refreshed[0].path, cache.path)
            // Retain the original inode elsewhere to ensure a replacement cannot reuse it.
            try FileManager.default.moveItem(atPath: cache.path, toPath: cache.path + ".old")
            try FileManager.default.createDirectory(atPath: cache.path, withIntermediateDirectories: true)
            XCTAssertThrowsError(try DiskAppDataRemoval.refreshedAfterQuitting([cache], home: home))
            let settings = try XCTUnwrap(candidates.first { $0.fileIdentity != nil })
            try Data(repeating: 3, count: 16384).write(to: URL(fileURLWithPath: settings.path))
            XCTAssertThrowsError(try DiskAppDataRemoval.refreshedAfterQuitting([settings], home: home))
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
