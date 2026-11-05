import Foundation
import Darwin
import XCTest
import MacSpaceSdk
import MacSpacePlatform
import MacSpaceDiskMapPrivileged
@testable import MacSpaceDiskMap

final class DiskUninstallBatchTests: XCTestCase {
    private func fixture(_ work: (String, DiskApplications) throws -> Void) throws {
        let home = "/private/tmp/uninstall-batch-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: home) }
        var owners: [AppOwner] = []
        for name in ["One", "Two"] {
            let path = home + "/Applications/" + name + ".app"
            try FileManager.default.createDirectory(atPath: path + "/Contents", withIntermediateDirectories: true)
            try (["CFBundleIdentifier": "org.fixture." + name.lowercased(), "CFBundleName": name] as NSDictionary).write(to: URL(fileURLWithPath: path + "/Contents/Info.plist"))
            owners.append(try XCTUnwrap(AppOwner(path: path)))
            let folder = home + "/Library/Application Support/" + name
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try Data(repeating: 1, count: 4096).write(to: URL(fileURLWithPath: folder + "/data"))
        }
        let catalog = AppCatalog(owners: owners), resolver = OwnershipResolver(catalog: catalog)
        var apps = DiskApplications(); apps.catalog = catalog; apps.catalogReadAt = Date()
        apps.apps = owners.map { owner in
            DiskApplication(owner: owner, bytes: 8192, dataPaths: [], removable: true, classification: .installedUser,
                ownership: resolver.claims(for: owner, home: home, systemLibrary: home + "/SystemLibrary"),
                plan: resolver.plan(for: owner, home: home, systemLibrary: home + "/SystemLibrary"))
        }
        try work(home, apps)
    }
    private func parameters(_ apps: [DiskApplication]) throws -> [String: String] {
        let selection = DiskMapScreenBuilder.uninstallSelection(apps, folder: nil)
        return ["ids": Selection.parameter(apps.map { $0.owner.path }),
            "reviewed": String(decoding: try JSONEncoder().encode(selection.reviewed), as: UTF8.self)]
    }
    func testCheckboxSelectionOpensCombinedReviewWithMandatoryAppsAndOptionalData() throws {
        try fixture { home, apps in
            let first = DiskMapScreenBuilder.appsPage(DiskIndex(root: home), apps: apps)
            XCTAssertEqual(first.selection?.choices.count, 2)
            XCTAssertTrue(first.selection?.checked.isEmpty == true)
            if case let .list(list) = first.widgets[0] {
                XCTAssertTrue(list.rows.allSatisfy { $0.actions.isEmpty && $0.pageID == nil })
            } else { XCTFail("Expected app list") }
            let plans = try XCTUnwrap(DiskUninstallBatch.plans(parameters: parameters(apps.apps), apps: apps))
            let selected = try XCTUnwrap(DiskUninstallBatch.resolve(plans, apps: apps))
            var index = DiskIndex(root: home)
            let pending = home + "/Library/Application Support/One"
            index.directories[pending] = DiskDirectory(path: pending, bytes: 0)
            let review = DiskMapScreenBuilder.uninstallReview(index, selected: selected, apps: apps, home: home)
            XCTAssertEqual(review.primary?.id, "uninstallSelected")
            XCTAssertEqual(review.selection?.includedBytes, 16384)
            XCTAssertEqual(review.selection?.choices.count, 2)
            XCTAssertTrue(review.selection?.checked.isEmpty == true)
            XCTAssertTrue(review.selection?.choices.values.allSatisfy { $0 > 0 } == true, "Data outside the snapshot must be measured for the selection total")
            let encoded = try XCTUnwrap(review.primary?.parameters["plans"])
            XCTAssertEqual(try JSONDecoder().decode([AppRemovalPlan].self, from: Data(encoded.utf8)).map { $0.owner.path }, selected.map { $0.owner.path })
            XCTAssertTrue(review.primary?.confirmation?.message.contains(selected[0].owner.path) == true)
            XCTAssertTrue(review.primary?.confirmation?.message.contains(selected[1].owner.path) == true)
        }
    }
    func testAppsAreSortedByDescendingSizeWithStableTies() throws {
        try fixture { home, original in
            var apps = original
            apps.apps[0].bytes = 1
            apps.apps[1].bytes = 8192
            let page = DiskMapScreenBuilder.appsPage(DiskIndex(root: home), apps: apps)
            guard case let .list(list) = page.widgets[0] else { return XCTFail("Expected app list") }
            XCTAssertEqual(list.rows.map(\.id), [apps.apps[1].owner.path, apps.apps[0].owner.path])
            XCTAssertEqual(DiskMapScreenBuilder.itemCount(1), loc("1 item"))
            XCTAssertEqual(DiskMapScreenBuilder.itemCount(0), loc("0 items"))
            XCTAssertEqual(DiskMapScreenBuilder.itemCount(2), loc("2 items"))
        }
    }
    func testStaleDuplicateAndForgedAppSelectionsRejectTheWholeBatchBeforeRemoval() throws {
        try fixture { home, apps in
            let frozen = try parameters(apps.apps)
            let plans = try XCTUnwrap(DiskUninstallBatch.plans(parameters: frozen, apps: apps))
            var bad = frozen; bad["ids"] = frozen["ids"]! + "\nforged"
            XCTAssertNil(DiskUninstallBatch.plans(parameters: bad, apps: apps))
            bad["ids"] = Selection.parameter([apps.apps[0].owner.path, apps.apps[0].owner.path])
            XCTAssertNil(DiskUninstallBatch.plans(parameters: bad, apps: apps))
            XCTAssertThrowsError(try DiskUninstallBatch.validate(plans, apps: apps, home: home, running: [apps.apps[1].owner.identifier]))
            try Data("changed".utf8).write(to: URL(fileURLWithPath: apps.apps[1].owner.path + "/new-file"))
            XCTAssertThrowsError(try DiskUninstallBatch.validate(plans, apps: apps, home: home, running: []))
            XCTAssertTrue(apps.apps.allSatisfy { FileManager.default.fileExists(atPath: $0.owner.path) })
            XCTAssertTrue(FileManager.default.fileExists(atPath: home + "/Library/Application Support/One/data"))
        }
    }
    func testUnselectedAppDataCannotBeAddedAndSharedDataRemainsExcluded() throws {
        try fixture { home, apps in
            let selected = [apps.apps[0]]
            let candidates = DiskUninstallBatch.dataCandidates(selected, apps: apps, home: home)
            let other = try XCTUnwrap(DiskUninstallBatch.dataCandidates([apps.apps[1]], apps: apps, home: home).first)
            XCTAssertThrowsError(try DiskAppDataRemoval.remove(ids: [other.id], candidates: candidates, moveToTrash: false, home: home))
            let plans = selected.compactMap(DiskUninstallBatch.plan)
            XCTAssertEqual(try DiskUninstallBatch.validate(plans, apps: apps, home: home, running: []).count, 1)
            var shared = apps
            let common = home + "/Library/Application Support/Shared"
            try FileManager.default.createDirectory(atPath: common, withIntermediateDirectories: true)
            for n in shared.apps.indices {
                shared.apps[n].ownership.append(.init(paths: [common], ownerPaths: shared.apps.map { $0.owner.path }, confidence: .shared, source: "fixture", reason: "Shared"))
            }
            XCTAssertFalse(DiskUninstallBatch.dataCandidates(shared.apps, apps: shared, home: home).contains { $0.path == common })
        }
    }
    func testSharedCoverageMatchesPairwiseOwnershipIncludingAncestorsAndUnicodeBoundaries() throws {
        try fixture { _, original in
            var apps = original
            let extra = [["/data/A", "/data/é/node", "/data/own"], ["/data/A/shared", "/data/AB", "/data/e\u{301}", "/data/雪"]]
            for n in apps.apps.indices {
                apps.apps[n].ownership.append(.init(paths: extra[n], ownerPaths: [apps.apps[n].owner.path], confidence: .unknown, source: "fixture", reason: "Coverage"))
            }
            for rootClaim in [false, true] {
                if rootClaim {
                    apps.apps[1].ownership.append(.init(paths: ["/"], ownerPaths: [apps.apps[1].owner.path], confidence: .unknown, source: "fixture", reason: "Root"))
                }
                let coverage = DiskAppDataRemoval.Coverage(apps: apps.apps)
                for app in apps.apps {
                    let foreign = apps.apps.filter { $0.owner.path != app.owner.path }.flatMap(\.ownership).flatMap(\.paths)
                    for path in ["/", "/data", "/data/A", "/data/A/leaf", "/data/AB", "/data/ABC", "/data/é", "/data/e\u{301}/node/child", "/data/雪", "/data/雪/leaf"] + apps.apps.map({ $0.owner.path }) {
                        let expected = foreign.contains { path == $0 || path.hasPrefix($0 == "/" ? "/" : $0 + "/") || $0.hasPrefix(path == "/" ? "/" : path + "/") }
                        XCTAssertEqual(coverage.blocks(path, owner: app.owner.path), expected, path)
                    }
                }
            }
        }
    }
}
