import Foundation
import XCTest
import MacSpaceDiskMapPrivileged
@testable import MacSpaceDiskMap

final class OwnershipEvidenceTests: XCTestCase {
    func testEmbeddedIdentifiersDoNotAssociatePublisherRootsWithOneApp() throws {
        try fixture { home in
            let owner = try app(home, name: "Install macOS Tahoe", id: "com.apple.InstallAssistant")
            let system = home + "/SystemLibrary"
            for library in [home + "/Library", system] {
                try file(library + "/Application Support/Apple/data")
                try file(library + "/Application Support/InstallAssistant/data")
            }
            let resolver = OwnershipResolver(catalog: AppCatalog(owners: [owner]),
                embeddedIdentifiers: [owner.path: ["com.apple.InstallAssistant.helper"]],
                availableDataPaths: [system + "/Application Support/Apple", system + "/Application Support/InstallAssistant"])
            let claims = resolver.claims(for: owner, home: home, systemLibrary: system)
            XCTAssertFalse(claims.flatMap(\.paths).contains { $0.hasSuffix("/Application Support/Apple") })
            XCTAssertTrue(claims.flatMap(\.paths).contains(system + "/Application Support/InstallAssistant"))
            XCTAssertTrue(OwnershipResolver.componentDataNames(["com.apple.InstallAssistant"]).contains("apple"),
                          "Broad unmatched-data protection must keep its existing exclusion evidence")
        }
    }

    func testDisplayNameMatchingExcludesPublisherRootsButKeepsDeclaredSupportPaths() throws {
        try fixture { home in
            let owner = try app(home, name: "Example", id: "com.vendor.product")
            let system = home + "/SystemLibrary"
            try file(system + "/Application Support/Vendor/data")
            try file(system + "/Application Support/Vendor/Product/data")
            try file(system + "/Application Support/Engine/data")
            let resolver = OwnershipResolver(catalog: AppCatalog(owners: [owner]),
                embeddedIdentifiers: [owner.path: ["com.vendor.engine"]],
                availableDataPaths: [system + "/Application Support/Vendor", system + "/Application Support/Engine"])
            let claims = resolver.claims(for: owner, home: home, systemLibrary: system)
            XCTAssertFalse(claims.flatMap(\.paths).contains(system + "/Application Support/Vendor"))
            XCTAssertTrue(claims.contains { $0.paths == [system + "/Application Support/Vendor/Product"] && $0.source == "declaredSupportPath" })
            XCTAssertTrue(claims.flatMap(\.paths).contains(system + "/Application Support/Engine"))
        }
    }
    private func fixture(_ body: (String) throws -> Void) throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("ownership-evidence-" + UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: root + "/Applications", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try body(root)
    }
    private func app(_ home: String, name: String = "Example", id: String = "org.example.product", background: Bool = false) throws -> AppOwner {
        let path = home + "/Applications/" + name + ".app"
        try FileManager.default.createDirectory(atPath: path + "/Contents", withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleName": name, "LSBackgroundOnly": background, "CrProductDirName": "Vendor/Product"]
        try (info as NSDictionary).write(to: URL(fileURLWithPath: path + "/Contents/Info.plist"))
        return try XCTUnwrap(AppOwner(path: path, knownIdentifiers: []))
    }
    private func file(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 8192).write(to: URL(fileURLWithPath: path))
    }
    func testIncompleteCatalogNeverProvesExclusiveDataOrOrphans() throws {
        try fixture { home in
            var owner = try app(home)
            owner.signatureValid = true // Injectable signed fixture, not an on-disk trust assertion.
            owner.groups = ["group.org.example.shared"]
            let container = home + "/Library/Containers/" + owner.identifier
            try file(container + "/Data/payload")
            try (["MCMMetadataIdentifier": owner.identifier] as NSDictionary).write(to: URL(fileURLWithPath: container + "/.com.apple.containermanagerd.metadata.plist"))
            try file(home + "/Library/Group Containers/" + owner.groups[0] + "/payload")
            let resolver = OwnershipResolver(catalog: AppCatalog(owners: [owner]))
            let claims = resolver.claims(for: owner, home: home, systemLibrary: home + "/SystemLibrary")
            XCTAssertEqual(claims.first { $0.source == "containerMetadata" }?.confidence, .unknown)
            XCTAssertEqual(claims.first { $0.source == "signedAppGroup" }?.confidence, .unknown)
            XCTAssertEqual(resolver.plan(for: owner, home: home, systemLibrary: home + "/SystemLibrary").targets.map(\.path), [owner.path])
        }
    }
    func testDuplicateInstallationsProtectSharedIdentifierDataAndGroups() throws {
        try fixture { home in
            var one = try app(home), two = try app(home, name: "Copy")
            one.groups = ["group.org.example.shared"]; two.groups = one.groups
            try file(home + "/Library/Caches/" + one.identifier + "/payload")
            try file(home + "/Library/Group Containers/" + one.groups[0] + "/payload")
            let resolver = OwnershipResolver(catalog: AppCatalog(owners: [one, two]))
            let claims = resolver.claims(for: one, home: home, systemLibrary: home + "/SystemLibrary")
            XCTAssertTrue(claims.filter { $0.source != "bundle" }.allSatisfy { $0.confidence == .shared })
            XCTAssertEqual(claims.first { $0.source == "signedAppGroup" }?.ownerPaths.count, 2)
        }
    }
    func testNamesAndVendorMetadataDoNotAuthorizeDeletion() throws {
        try fixture { home in
            let owner = try app(home)
            try file(home + "/Library/Application Support/Example/payload")
            try file(home + "/Library/Application Support/Vendor/Product/payload")
            try file(home + "/Library/Caches/" + owner.identifier + "/payload")
            let resolver = OwnershipResolver(catalog: AppCatalog(owners: [owner], discoveryComplete: true))
            let claims = resolver.claims(for: owner, home: home, systemLibrary: home + "/SystemLibrary")
            XCTAssertTrue(claims.contains { $0.paths.contains(home + "/Library/Application Support/Vendor/Product") && $0.confidence == .inferred })
            XCTAssertTrue(claims.contains { $0.paths.contains(home + "/Library/Application Support/Example") && $0.confidence == .inferred })
            XCTAssertEqual(claims.first { $0.source == "identifierConvention" }?.confidence, .inferred)
            XCTAssertEqual(resolver.plan(for: owner, home: home, systemLibrary: home + "/SystemLibrary").targets.map(\.path), [owner.path])
        }
    }
    func testClassificationAllowsAppleAppsButPreservesLifecycleAndBackground() throws {
        try fixture { home in
            let apple = try app(home, id: "com.apple.optional")
            XCTAssertEqual(AppOwnership.classification(apple, home: home).0, .installedUser)
            let own = try app(home, name: "MacSpace", id: "com.macspace.app")
            XCTAssertEqual(AppOwnership.classification(own, home: home).0, .macSpaceLifecycle)
            let agent = try app(home, name: "Agent", background: true)
            XCTAssertEqual(AppOwnership.classification(agent, home: home).0, .background)
            let menuPath = home + "/Applications/Menu.app"
            try FileManager.default.copyItem(atPath: apple.path, toPath: menuPath)
            let menuInfo = try XCTUnwrap(NSMutableDictionary(contentsOfFile: menuPath + "/Contents/Info.plist"))
            menuInfo["LSUIElement"] = true
            XCTAssertTrue(menuInfo.write(toFile: menuPath + "/Contents/Info.plist", atomically: true))
            XCTAssertEqual(AppOwnership.classification(try XCTUnwrap(AppOwner(path: menuPath)), home: home).0, .installedUser)
            var external = apple; external.path = home + "/Elsewhere.app"
            try FileManager.default.copyItem(atPath: apple.path, toPath: external.path)
            XCTAssertEqual(AppOwnership.classification(external, home: home).0, .extraCopy)
            XCTAssertEqual(AppOwnership.classification(external, home: home, registered: [external.path]).0, .installedUser)
            XCTAssertEqual(AppOwnership.classification(external, home: home, registered: [external.path], candidates: [apple, external]).0, .extraCopy)
        }
    }
    func testExactPlanRoundTripAndExecutionNeverExpandsTargets() throws {
        try fixture { home in
            let owner = try app(home), catalog = AppCatalog(owners: [])
            let plan = OwnershipResolver(catalog: catalog).plan(for: owner, home: home, systemLibrary: home + "/SystemLibrary")
            let roundtrip = try JSONDecoder().decode(AppRemovalPlan.self, from: Data(plan.encoded().utf8))
            XCTAssertEqual(roundtrip, plan)
            try file(home + "/Library/Caches/" + owner.identifier + "/new-data")
            var removed: [String] = []
            let result = AppRemovalExecutor.execute(plan: plan, catalog: catalog, home: home, systemLibrary: home + "/SystemLibrary", remove: { removed.append($0) })
            XCTAssertTrue(result.failures.isEmpty)
            XCTAssertEqual(removed, [owner.path])
            XCTAssertTrue(FileManager.default.fileExists(atPath: owner.path))
        }
    }
    func testForgedOrOverlappingPlanFailsBeforeAnySideEffect() throws {
        try fixture { home in
            let owner = try app(home), catalog = AppCatalog(owners: [])
            var plan = OwnershipResolver(catalog: catalog).plan(for: owner, home: home, systemLibrary: home + "/SystemLibrary")
            let innocent = home + "/Documents/important"; try file(innocent)
            var forged = try XCTUnwrap(plan.targets.first)
            forged.path = innocent; forged.identity = try XCTUnwrap(AppFileIdentity(path: innocent))
            forged.evidence.paths = [innocent]
            plan.targets.append(forged)
            var calls = 0
            XCTAssertFalse(AppRemovalExecutor.execute(plan: plan, catalog: catalog, home: home, systemLibrary: home + "/SystemLibrary", remove: { _ in calls += 1 }).failures.isEmpty)
            XCTAssertEqual(calls, 0)
            plan.targets = [plan.targets[0], plan.targets[0]]
            XCTAssertNotNil(AppRemovalExecutor.validate(plan: plan, catalog: catalog, home: home, systemLibrary: home + "/SystemLibrary"))
        }
    }
    func testStaleIdentityAndMissingLegacyPlanFailClosed() throws {
        try fixture { home in
            let owner = try app(home), catalog = AppCatalog(owners: [])
            let plan = OwnershipResolver(catalog: catalog).plan(for: owner, home: home, systemLibrary: home + "/SystemLibrary")
            try file(owner.path + "/new-file")
            XCTAssertNotNil(AppRemovalExecutor.validate(plan: plan, catalog: catalog, home: home, systemLibrary: home + "/SystemLibrary"))
            var calls = 0
            let legacy = AppRemovalExecutor.execute(owner: owner, installed: [owner], home: home, systemLibrary: home + "/SystemLibrary", remove: { _ in calls += 1 })
            XCTAssertFalse(legacy.failures.isEmpty); XCTAssertEqual(calls, 0)
        }
    }
    func testChangedPlistMetadataRejectsPreviouslyReviewedPlan() throws {
        try fixture { home in
            let owner = try app(home), catalog = AppCatalog(owners: [])
            let plan = OwnershipResolver(catalog: catalog).plan(for: owner, home: home, systemLibrary: home + "/SystemLibrary")
            let path = owner.path + "/Contents/Info.plist"
            let info = try XCTUnwrap(NSMutableDictionary(contentsOfFile: path))
            info["CFBundleVersion"] = "new-version"
            XCTAssertTrue(info.write(toFile: path, atomically: true))
            XCTAssertNotNil(AppRemovalExecutor.validate(plan: plan, catalog: catalog, home: home, systemLibrary: home + "/SystemLibrary"))
        }
    }
    func testFileAndContainingDirectoryUnionDoesNotDoubleCount() throws {
        try fixture { home in
            let folder = home + "/data", path = folder + "/small"
            try file(path)
            var index = DiskIndex(root: home)
            let size = DiskApplications.measuredBytes([path], index: index)
            index.directories[folder] = DiskDirectory(path: folder, directBytes: size, bytes: size)
            XCTAssertEqual(DiskApplications.measuredBytes([folder, path], index: index), size)
        }
    }
    func testPathUnionAndSmallFileMeasurement() throws {
        try fixture { home in
            let path = home + "/Library/Preferences/org.example.product.plist"; try file(path)
            let index = DiskIndex(root: home)
            let size = DiskApplications.measuredBytes([path, path], index: index)
            XCTAssertGreaterThan(size, 0)
            XCTAssertEqual(size, DiskApplications.measuredBytes([path], index: index))
            XCTAssertEqual(AppOwnership.normalizedPaths([home + "/A", home + "/A/B", home + "/AB", home + "/A"]), [home + "/A", home + "/AB"])
            let alias = home + "/alias"; try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: path)
            XCTAssertNil(AppFileIdentity(path: alias))
        }
    }
    func testAttributionInternsEvidenceAndPreservesSharedOverlaps() throws {
        try fixture { home in
            let owner = try app(home)
            let shared = DiskOwnershipClaim(paths: [owner.path + "/Shared"], ownerPaths: [owner.path, "/another.app"], confidence: .shared, source: "fixture", reason: "Two owners")
            let bundle = OwnershipResolver(catalog: AppCatalog(owners: [owner])).claims(for: owner, home: home, systemLibrary: home + "/SystemLibrary")[0]
            var apps = DiskApplications()
            apps.apps = [DiskApplication(owner: owner, bytes: 0, dataPaths: [], removable: true, metadataStamp: nil, ownership: [bundle, shared])]
            let db = try DiskDatabase(url: URL(fileURLWithPath: home + "/index.sqlite"), root: home)
            for path in [owner.path, owner.path + "/Contents", owner.path + "/Shared", owner.path + "/Shared/child"] { try db.put(DiskDirectory(path: path, ownerUID: 501)) }
            try db.recordOwnership(apps)
            let index = try db.snapshot(folder: owner.path, inventory: false).index
            XCTAssertEqual(index.directories[owner.path]?.ownershipID, index.directories[owner.path + "/Contents"]?.ownershipID)
            XCTAssertEqual(index.directories[owner.path]?.ownerUID, 501)
            XCTAssertEqual(try db.ownershipEvidence(owner.path + "/Shared/child")?.confidence, .shared)
            XCTAssertEqual(try db.ownershipEvidence(owner.path + "/Contents")?.confidence, .verifiedExclusive)
            try db.recordOwnership(DiskApplications())
            XCTAssertNil(try db.ownershipEvidence(owner.path))

        }
    }
    func testReceiptPathsAreUnknownEvenWithACompleteReadableManifest() throws {
        try fixture { home in
            let owner = try app(home)
            let manifest = AppReceiptReader.manifest(identifier: "unrelated.package.identifier", installPrefix: home + "/Applications",
                listing: "./Example.app/Contents/Info.plist\n./Shared/support.dat\n", complete: true)
            XCTAssertTrue(manifest.complete)
            var receipts = AppReceiptCatalog(); receipts.manifests = [manifest]; receipts.complete = true
            let claims = try XCTUnwrap(receipts.claims(owners: [owner])[owner.path])
            XCTAssertEqual(claims.count, 2)
            XCTAssertTrue(claims.allSatisfy { $0.confidence == .unknown && $0.source == "receiptManifest:unrelated.package.identifier" })
            let plan = OwnershipResolver(catalog: AppCatalog(owners: [owner])).plan(for: owner, home: home, systemLibrary: home + "/SystemLibrary")
            XCTAssertEqual(plan.targets.map(\.path), [owner.path])
            XCTAssertEqual(plan.catalogCandidates, [owner.path])
            var apps = DiskApplications()
            let bundle = DiskOwnershipClaim(paths: [owner.path], ownerPaths: [owner.path], confidence: .verifiedExclusive, source: "bundle", reason: "installation")
            apps.apps = [DiskApplication(owner: owner, bytes: 0, dataPaths: [], removable: true, metadataStamp: nil, ownership: [bundle] + claims)]
            let db = try DiskDatabase(url: URL(fileURLWithPath: home + "/index.sqlite"), root: home)
            try db.recordOwnership(apps)
            let evidence = try XCTUnwrap(db.ownershipEvidence(owner.path + "/Contents/Info.plist"))
            XCTAssertEqual(evidence.confidence, .unknown)
            XCTAssertTrue(evidence.source.contains("receiptManifest:unrelated.package.identifier"))

        }
    }
    func testReceiptParserRejectsTraversalAndDoesNotMatchByPackageName() throws {
        try fixture { home in
            let owner = try app(home)
            let malformed = AppReceiptReader.manifest(identifier: owner.identifier, installPrefix: home, listing: "../escape\n/absolute\n./safe\n", complete: true)
            XCTAssertFalse(malformed.complete)
            XCTAssertEqual(malformed.paths, [home + "/safe"])
            var receipts = AppReceiptCatalog(); receipts.manifests = [malformed]
            XCTAssertTrue(receipts.claims(owners: [owner]).isEmpty)
            XCTAssertTrue(AppReceiptReader.manifest(identifier: "test", installPrefix: "../../", listing: "file", complete: true).paths.isEmpty)
        }
    }
    func testReadOnlyReceiptReaderUsesFixtureBOMAndCachesUnchangedManifest() throws {
        try fixture { home in
            let payload = home + "/Payload", receiptsPath = home + "/Receipts"
            try file(payload + "/Example.app/Contents/Info.plist")
            try FileManager.default.createDirectory(atPath: receiptsPath, withIntermediateDirectories: true)
            try (["PackageIdentifier": "fixture.receipt", "InstallPrefixPath": home + "/Applications"] as NSDictionary)
                .write(to: URL(fileURLWithPath: receiptsPath + "/fixture.plist"))
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/mkbom")
            process.arguments = [payload, receiptsPath + "/fixture.bom"]
            try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
            let first = AppReceiptReader.read(directory: receiptsPath, budget: 5)
            XCTAssertTrue(first.complete); XCTAssertEqual(first.manifests.count, 1)
            XCTAssertTrue(first.manifests[0].paths.contains(home + "/Applications/Example.app/Contents/Info.plist"))
            let persisted = try JSONDecoder().decode(AppReceiptCatalog.self, from: JSONEncoder().encode(first))
            let second = AppReceiptReader.read(previous: persisted, directory: receiptsPath, budget: 5)
            XCTAssertEqual(first.manifests, second.manifests)
            try file(payload + "/Example.app/Contents/new-file")
            let rebuilt = Process(); rebuilt.executableURL = URL(fileURLWithPath: "/usr/bin/mkbom")
            rebuilt.arguments = [payload, receiptsPath + "/fixture.bom"]
            try rebuilt.run(); rebuilt.waitUntilExit(); XCTAssertEqual(rebuilt.terminationStatus, 0)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: receiptsPath + "/fixture.bom")
            let changed = AppReceiptReader.read(previous: persisted, directory: receiptsPath, budget: 5)
            XCTAssertTrue(changed.manifests[0].paths.contains(home + "/Applications/Example.app/Contents/new-file"),
                "Persisted manifests must be invalidated when their source BOM stamp changes")
            let bounded = AppReceiptReader.read(directory: receiptsPath, budget: 0)
            XCTAssertFalse(bounded.complete); XCTAssertTrue(bounded.manifests.isEmpty)
        }
    }
    func testAppPresentationCountsInstalledAppsAndCarriesExactPlanWithoutExpandingRow() throws {
        try fixture { home in
            let owner = try app(home), catalog = AppCatalog(owners: [])
            let plan = OwnershipResolver(catalog: catalog).plan(for: owner, home: home, systemLibrary: home + "/SystemLibrary")
            var installed = DiskApplication(owner: owner, bytes: 4096, dataPaths: [], removable: true, metadataStamp: nil, classification: .installedUser, plan: plan)
            installed.ownership = [DiskOwnershipClaim(paths: [home + "/Library/Example"], ownerPaths: [owner.path], confidence: .inferred, source: "fixture", reason: "inferred")]
            var protected = installed; protected.classification = .protectedSystem; protected.removable = false; protected.plan = nil
            var apps = DiskApplications(); apps.apps = [installed, protected]; apps.catalogReadAt = Date()
            let page = DiskMapScreenBuilder.appsPage(DiskIndex(root: home), apps: apps)
            guard case let .list(list) = page.widgets[0] else { return XCTFail() }
            XCTAssertEqual(list.rows.count, 1)
            XCTAssertEqual(list.rows[0].iconPath, owner.path)
            XCTAssertTrue(list.rows[0].children.isEmpty)
            XCTAssertTrue(list.rows[0].actions.isEmpty)
            XCTAssertNil(list.rows[0].pageID, "App selection uses a checkbox rather than a per-app drill-down")
            XCTAssertEqual(page.selection?.choices, [owner.path: installed.bytes])
            XCTAssertTrue(page.selection?.checked.isEmpty == true)
            XCTAssertEqual(page.selection?.action.pageID, DiskUninstallBatch.reviewDestination)
            XCTAssertNil(page.selection?.action.confirmation, "Opening review must not mutate anything")
            XCTAssertNotNil(page.selection?.reviewed[owner.path])
            let encoded = try XCTUnwrap(DiskMapScreenBuilder.uninstallAction(installed)?.parameters["plan"])
            XCTAssertEqual(try JSONDecoder().decode(AppRemovalPlan.self, from: Data(encoded.utf8)), plan)
            XCTAssertTrue(DiskMapScreenBuilder.appRow(protected).actions.isEmpty)
        }
    }

}

extension OwnershipEvidenceTests {
    func testFileAllocationMeasurementsAreReusedOnlyWithinTheSameScanRevision() throws {
        try fixture { home in
            let owner = try app(home), path = home + "/data/file"
            try file(path)
            var apps = DiskApplications()
            apps.apps = [DiskApplication(owner: owner, bytes: 0, dataPaths: [], removable: false,
                ownership: [.init(paths: [path], ownerPaths: [owner.path], confidence: .unknown, source: "fixture", reason: "Historical")])]
            var index = DiskIndex(root: home); index.inventoryAuthoritative = true; index.revision = 1
            let first = apps.remeasured(index)
            let bytes = try XCTUnwrap(first.apps.first?.dataBytes)
            XCTAssertGreaterThan(bytes, 0)
            try Data(repeating: 1, count: 131_072).write(to: URL(fileURLWithPath: path))
            XCTAssertEqual(first.remeasured(index).apps.first?.dataBytes, bytes, "Status reads use the already measured snapshot")
            index.revision = 2
            XCTAssertGreaterThan(try XCTUnwrap(first.remeasured(index).apps.first?.dataBytes), bytes)
            index.revision = 1; index.measuredOwnershipBytes = [path: 77]
            XCTAssertEqual(first.remeasured(index).apps.first?.dataBytes, 77, "Authoritative index figures override fallback observations")
        }
    }
}
