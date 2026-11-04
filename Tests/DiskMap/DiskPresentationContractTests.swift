import Darwin
import Foundation
import XCTest
import MacSpaceSdk
import MacSpacePlatform
import MacSpaceDiskMapPrivileged
@testable import MacSpaceDiskMap

final class DiskPresentationContractTests: XCTestCase {
    private let home = FileManager.default.homeDirectoryForCurrentUser.path

    private func identity(_ inode: UInt64 = 1) -> FileReviewIdentity {
        var value = stat()
        value.st_dev = 1; value.st_ino = inode; value.st_uid = getuid(); value.st_size = 100_000_000
        return FileReviewIdentity(value)
    }
    private func file(_ relative: String, inode: UInt64 = 1) -> DiskFile {
        DiskFile(path: home + "/" + relative, bytes: 4096, logicalBytes: 100_000_000, ownerUID: getuid(), identity: identity(inode))
    }
    private func lists(_ screen: Screen) -> [ListWidget] {
        screen.widgets.compactMap { if case let .list(list) = $0 { return list }; return nil }
    }

    func testOverviewPlacesFilesAboveFolders() {
        let index = DiskIndex(root: "/")
        XCTAssertEqual(lists(DiskMapScreenBuilder.screen(index, apps: DiskApplications())).map(\.id),
            ["apps-class", "large-files", "personal-folders"])
    }

    func testGraphFilesExposeOnlyReviewedEligibleDeletionAndFoldersDeclareCapabilities() throws {
        let eligible = file("Downloads/graph.zip")
        let selection = DiskMapScreenBuilder.fileSelection([eligible], open: [:])
        let actions = DiskMapScreenBuilder.fileContextActions(eligible, selection: selection)
        let deletion = try XCTUnwrap(actions.delete)
        XCTAssertEqual(actions.paths, [eligible.path])
        XCTAssertEqual(deletion.id, "deleteGraphFile")
        XCTAssertEqual(deletion.parameters["id"], DiskMapScreenBuilder.fileID(eligible.path))
        XCTAssertEqual(deletion.parameters["reviewed"], selection.reviewed[DiskMapScreenBuilder.fileID(eligible.path)])
        XCTAssertTrue(deletion.confirmation?.message.contains(eligible.path) == true)
        XCTAssertEqual(deletion.requires, [.fullDiskAccess])
        let managed = file("Pictures/Photos.photoslibrary/data")
        XCTAssertNil(DiskMapScreenBuilder.fileContextActions(managed, selection: DiskMapScreenBuilder.fileSelection([managed], open: [:])).delete)
        var changed = eligible; changed.identity = nil
        XCTAssertNil(DiskMapScreenBuilder.fileContextActions(changed, selection: DiskMapScreenBuilder.fileSelection([changed], open: [:])).delete)
        var index = DiskIndex(root: "/")
        index.directories["/"] = DiskDirectory(path: "/", folders: [home + "/Downloads"])
        index.directories[home + "/Downloads"] = DiskDirectory(path: home + "/Downloads", bytes: 8192)
        let folder = try XCTUnwrap(DiskMapScreenBuilder.segments(index, folder: "/").first)
        XCTAssertEqual(folder.contextActions?.paths, [home + "/Downloads"])
        XCTAssertEqual(folder.contextActions?.delete, folder.items.first?.contextActions?.delete)
    }

    func testModuleRootAndTileUseAppsAndFilesName() {
        var index = DiskIndex(root: "/")
        index.directories["/"] = DiskDirectory(path: "/")
        XCTAssertEqual(DiskMapScreenBuilder.tile(index).title, "Apps and files")
        XCTAssertEqual(DiskMapScreenBuilder.screen(index, apps: DiskApplications()).title, "Apps and files")
    }

    func testRootShowsDuplicatesFirstAndOnlyNonemptyContentCategories() throws {
        var index = DiskIndex(root: "/")
        index.directories["/"] = DiskDirectory(path: "/")
        index.overviewFiles = [file("Downloads/raw-preview.zip")]
        index.duplicateCount = 1; index.duplicateBytes = 4096
        index.personalFolders = [DiskDirectory(path: home + "/Downloads", bytes: 4096)]
        index.categories = [.init(category: .archives, bytes: 4096, count: 1), .init(category: .installers, bytes: 0, count: 0),
            .init(category: .media, bytes: 8192, count: 2), .init(category: .other, bytes: 0, count: 0)]
        let screen = DiskMapScreenBuilder.screen(index, apps: DiskApplications())
        let groups = lists(screen)
        XCTAssertEqual(groups.map(\.id), ["apps-class", "large-files", "personal-folders"])
        XCTAssertEqual(groups.first { $0.id == "large-files" }?.rows.map(\.title), ["Duplicate files", "Archives", "Media"])
        XCTAssertFalse(groups.flatMap(\.rows).contains { $0.id.hasPrefix("file:") || $0.title == "Recommended" || $0.title == "Developer cleanup" })
        XCTAssertEqual(groups.first { $0.id == "personal-folders" }?.rows.first?.pageID, DiskMapScreenBuilder.folderID(home + "/Downloads"))
        XCTAssertEqual(screen.selection?.scope, "disk-files")
        XCTAssertEqual(screen.selection?.session, true)
        XCTAssertEqual(screen.selection?.bulkResolver, "selection:")
    }

    func testEmptyOrUnknownScopedSummariesDoNotCreateCategoryDestinations() throws {
        let folder = home + "/Documents"
        let summariesToCheck: [[DiskCategorySummary]?] = [nil, [], DiskCategory.inventoryCategories.map { .init(category: $0, bytes: 0, count: 0) }]
        for summaries in summariesToCheck {
            var index = DiskIndex(root: "/")
            index.categories = summaries
            index.directories[folder] = DiskDirectory(path: folder)
            let screen = DiskMapScreenBuilder.screen(index, apps: DiskApplications(), folder: folder)
            let inventory = try XCTUnwrap(lists(screen).first { $0.id == "large-files" })
            XCTAssertTrue(inventory.rows.isEmpty)
            XCTAssertNil(inventory.rows.first?.trailing)
            XCTAssertNil(inventory.rows.first?.subtitle)
        }
        var root = DiskIndex(root: "/")
        root.categories = []; root.duplicateCount = 0; root.duplicateBytes = 0
        let pending = try XCTUnwrap(lists(DiskMapScreenBuilder.screen(root, apps: DiskApplications())).first { $0.id == "large-files" })
        XCTAssertTrue(pending.rows.isEmpty)
        XCTAssertNil(pending.rows.first?.trailing)
        XCTAssertNil(pending.rows.first?.subtitle)
        var scoped = DiskIndex(root: "/")
        scoped.categories = [.init(category: .installers, bytes: 8192, count: 1)]
        scoped.directories[folder] = DiskDirectory(path: folder)
        let inventory = try XCTUnwrap(lists(DiskMapScreenBuilder.screen(scoped, apps: DiskApplications(), folder: folder)).first { $0.id == "large-files" })
        XCTAssertEqual(inventory.rows.map(\.title), ["Installers"])
        XCTAssertEqual(DiskBrowseRequest(id: try XCTUnwrap(inventory.rows.last?.pageID))?.folder, folder)
    }

    func testCategoryAndFolderHeadersResolveCurrentSizeScopeAcrossPages() throws {
        let files = [file("Downloads/A/one.zip"), file("Downloads/B/two.zip", inode: 2)]
        let request = DiskBrowseRequest(folder: home + "/Downloads", kind: .category, category: .archives)
        let page = DiskBrowsePage(request: request, files: files, ownership: [:])
        let screen = DiskMapScreenBuilder.browsePage(page)
        let headers = try XCTUnwrap(screen.selection?.sections)
        XCTAssertEqual(headers.count, 1)
        for header in headers {
            let id = try XCTUnwrap(header.pageID)
            XCTAssertTrue(id.hasPrefix("select:"))
            let scope = try XCTUnwrap(DiskBrowseRequest(id: String(id.dropFirst(7))))
            XCTAssertEqual(scope.category, .archives)
            XCTAssertFalse(scope.includeSmaller)
            XCTAssertNil(scope.afterPath)
            XCTAssertNil(scope.afterSize)
        }
        XCTAssertNil(DiskBrowseRequest(id: String(try XCTUnwrap(headers.first?.pageID).dropFirst(7)))?.selectionParent)
        XCTAssertTrue(headers.allSatisfy { DiskBrowseRequest(id: String($0.pageID!.dropFirst(7)))?.selectionParent == nil })
        XCTAssertEqual(headers.compactMap { DiskBrowseRequest(id: String($0.pageID!.dropFirst(7)))?.fileType }, ["ext:zip"])
        XCTAssertEqual(lists(screen).flatMap(\.rows).filter { $0.sectionID != nil && !$0.paths.isEmpty }.count, 0)
        XCTAssertEqual(lists(screen).filter { $0.id != "smaller-files" }.count, 1)
        XCTAssertTrue(lists(screen).flatMap(\.rows).allSatisfy { $0.sectionID == nil }, "Type headings belong outside the file list")
        XCTAssertFalse(lists(screen).flatMap(\.rows).contains { $0.title == "Open folder in Finder" })

        var next = request; next.afterPath = files[0].path; next.afterSize = files[0].logicalBytes
        XCTAssertEqual(DiskMapScreenBuilder.selectionPageID(request), DiskMapScreenBuilder.selectionPageID(next))
        var other = request; other.category = .media
        XCTAssertNotEqual(DiskMapScreenBuilder.selectionPageID(request), DiskMapScreenBuilder.selectionPageID(other))
    }

    func testShowAllFilesUsesNewListOnlyPageAndDoesNotPreselect() throws {
        let request = DiskBrowseRequest(folder: home + "/Downloads", kind: .category, category: .archives)
        let screen = DiskMapScreenBuilder.browsePage(.init(request: request, files: [], ownership: [:]))
        let row = try XCTUnwrap(lists(screen).last?.rows.last)
        XCTAssertEqual(row.title, "Show all files")
        XCTAssertFalse(row.replacesPage)
        var smaller = try XCTUnwrap(DiskBrowseRequest(id: XCTUnwrap(row.pageID)))
        XCTAssertEqual(smaller.folder, request.folder)
        XCTAssertEqual(smaller.category, request.category)
        XCTAssertTrue(smaller.includeSmaller)
        XCTAssertFalse(smaller.inFolder)
        let expanded = DiskMapScreenBuilder.browsePage(.init(request: smaller, files: [file("Downloads/small.zip")], ownership: [:]))
        XCTAssertTrue(expanded.selection?.checked.isEmpty == true)
        XCTAssertNil(expanded.hero)
        XCTAssertEqual(expanded.layout, .singleColumn)
        XCTAssertNotEqual(expanded.selection?.sections.first?.id, screen.selection?.sections.first?.id)
        XCTAssertFalse(lists(expanded).flatMap(\.rows).contains { $0.title == "Show all files" })
        smaller.afterPath = home + "/Downloads/small.zip"; smaller.afterSize = 1
        XCTAssertEqual(DiskMapScreenBuilder.selectionPageID({ var value = smaller; value.fileType = "ext:zip"; return value }()), expanded.selection?.sections.first?.pageID)
    }

    func testEveryDuplicateCopyIsSelectableAndCarriesOriginalProof() throws {
        var keeper = file("Downloads/A.zip"), copy = file("Downloads/B.zip", inode: 2)
        let proof = DiskDuplicateVerification(path: copy.path, identity: try XCTUnwrap(copy.identity), keeper: keeper.path,
            keeperIdentity: try XCTUnwrap(keeper.identity), digest: Data([1, 2, 3]))
        copy.duplicateVerification = proof
        keeper.duplicateVerification = .init(path: keeper.path, identity: keeper.identity!, keeper: copy.path, keeperIdentity: copy.identity!, digest: proof.digest)
        var page = DiskBrowsePage(request: .init(folder: home + "/Downloads", kind: .duplicates), files: [keeper, copy], ownership: [:])
        page.duplicateGroups = [.init(id: "digest", keeper: keeper, copies: [copy])]
        let screen = DiskMapScreenBuilder.browsePage(page), rows = lists(screen).flatMap(\.rows)
        XCTAssertFalse(rows.contains { $0.badges.contains { $0.text == "Retained copy" } })
        XCTAssertEqual(screen.selection?.choices[DiskFileRemoval.id(keeper.path)], keeper.bytes)
        let copyID = DiskFileRemoval.id(copy.path)
        XCTAssertEqual(screen.selection?.choices[copyID], copy.bytes)
        let origin = try XCTUnwrap(screen.selection?.origins[copyID])
        XCTAssertEqual(try JSONDecoder().decode(DiskDuplicateVerification.self, from: Data(origin.utf8)), proof)
        XCTAssertFalse(rows.contains { $0.actions.contains { $0.id == "findDuplicates" } || $0.title == "Compare files" })
        XCTAssertEqual(DiskMapScreenBuilder.fileSelection([keeper, copy], open: [:]).choices.count, 2)
    }

    func testOriginalReviewRejectsStaleFilesMissingProofAndSelectedKeeperAcrossFolders() throws {
        let normal = file("Documents/normal.txt", inode: 3), keeper = file("Downloads/A.zip"), duplicate = file("Downloads/B.zip", inode: 2)
        let proof = DiskDuplicateVerification(path: duplicate.path, identity: try XCTUnwrap(duplicate.identity), keeper: keeper.path,
            keeperIdentity: try XCTUnwrap(keeper.identity), digest: Data([1]))
        var marked = duplicate; marked.duplicateVerification = proof
        let selected = try XCTUnwrap(DiskMapModule.reviewedSelection([normal, marked], original: [normal, marked]))
        XCTAssertEqual(selected.map(\.path), [normal.path, duplicate.path])
        XCTAssertEqual(selected[1].duplicateVerification, proof)
        XCTAssertNotNil(DiskMapModule.reviewedSelection([normal, marked], original: [normal, duplicate]), "Newly discovered duplicate relationships are validated against the complete token before removal")
        var stale = normal; stale.identity = identity(99)
        XCTAssertNil(DiskMapModule.reviewedSelection([stale, marked], original: [normal, marked]))
        let includingKeeper = [normal, marked, keeper]
        XCTAssertNotNil(DiskMapModule.reviewedSelection(includingKeeper, original: includingKeeper), "The selection store reports survivor conflicts without silently changing choices")
        var refreshedProof = marked
        refreshedProof.duplicateVerification?.keeperIdentity = identity(99)
        XCTAssertEqual(DiskMapModule.reviewedSelection([normal, refreshedProof], original: [normal, marked])?[1].duplicateVerification, proof,
            "A freshly resolved proof must never replace the original reviewed keeper identity")
    }

    func testOpenProcessReasonExcludesChoiceWithoutChangingFileLocation() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([1]).write(to: url)
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let observed = try XCTUnwrap(OpenFileUse.inspect([url.path])[url.path])
        let file = file("Downloads/open.zip"), readers = [file.path: observed]
        let rows = DiskMapScreenBuilder.reviewRows([file], ownership: [:], open: readers)
        XCTAssertEqual(rows.first?.paths, [file.path])
        XCTAssertTrue(rows.first?.unavailableReason?.contains(observed[0].process) == true)
        XCTAssertTrue(DiskMapScreenBuilder.fileSelection([file], open: readers).choices.isEmpty)
    }

    func testApplicationsAliasUsesScopedAppsAndLabelsUnmatchedAsGlobal() throws {
        func owner(_ path: String, name: String) throws -> AppOwner {
            let values: [String: Any] = ["path": path, "identifier": "org.example." + name, "name": name,
                "groups": [], "helpers": [:], "identifiers": [], "isBackground": false, "signatureValid": false, "metadataDigest": "test"]
            let data = try JSONSerialization.data(withJSONObject: values)
            return try JSONDecoder().decode(AppOwner.self, from: data)
        }
        var apps = DiskApplications()
        apps.apps = try [("/Applications/One.app", "One"), (home + "/Applications/Two.app", "Two")].map { path, name in
            DiskApplication(owner: try owner(path, name: name), bytes: 4096, dataPaths: [], removable: false, classification: .installedUser)
        }
        apps.reviewableLeftovers = [.init(identifier: "org.example.unknown", path: home + "/Library/Containers/org.example.unknown", bytes: 4096)]
        let folder = DataVolume.path + "/Applications"
        var index = DiskIndex(root: "/"); index.directories[folder] = DiskDirectory(path: folder)
        let map = DiskMapScreenBuilder.screen(index, apps: apps, folder: folder)
        let rows = try XCTUnwrap(lists(map).first?.rows)
        XCTAssertEqual(rows.first?.pageID, DiskMapScreenBuilder.appsPageID(folder: folder))
        XCTAssertTrue(rows.contains { $0.title == "Unmatched app data" && $0.badges.contains { $0.text == "All locations" } })
        let page = DiskMapScreenBuilder.appsPage(index, apps: apps, folder: folder)
        XCTAssertEqual(lists(page).flatMap(\.rows).map(\.title), ["One"])
        let leftovers = DiskMapScreenBuilder.leftoversPage(apps)
        XCTAssertEqual(leftovers.selection?.action.parameters["trash"], "0")
        XCTAssertEqual(leftovers.selection?.action.confirmation?.confirmTitle, "Delete")
    }
}
