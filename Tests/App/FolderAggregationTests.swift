import XCTest
import MacSpaceSdk
@testable import MacSpaceApp

@MainActor
final class FolderAggregationTests: XCTestCase {
    func testFolderGroupingPreservesEveryDestinationAndExactTotals() throws {
        let folders = (0..<120).map { UsageSegment(id: "folder\($0)", label: "Folder \($0)", bytes: UInt64($0 + 1), tone: .series($0), pageID: "folder:/\($0)", kind: .folder) }
        let dominant = UsageSegment(id: "big", label: "Big", bytes: 100_000_000, tone: .series(0), pageID: "folder:/big", kind: .folder)
        let files = UsageSegment(id: "files", label: "Other files", bytes: 22, tone: .series(1), pageID: "files:/", kind: .files)
        let parts = folders + [dominant, files]
        let blocks = BlockLayout.blocks(parts)
        let aggregate = try XCTUnwrap(blocks.first { $0.segment.id == BlockLayout.foldersID }?.segment)
        XCTAssertEqual(aggregate.bytes, folders.reduce(0) { $0 + $1.bytes })
        XCTAssertEqual(Set(aggregate.items.compactMap(\.pageID)), Set(folders.compactMap(\.pageID)))
        XCTAssertEqual(blocks.reduce(UInt64(0)) { $0 + $1.segment.bytes }, parts.reduce(0) { $0 + $1.bytes })
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(BlockLayout.legendSegments(parts).map(\.id), blocks.map(\.segment.id))
        XCTAssertTrue(blocks.contains { $0.segment.id == "files" })
        XCTAssertGreaterThan(try XCTUnwrap(blocks.first { $0.segment.id == aggregate.id }?.weight), Double(aggregate.bytes))
        let screen = Screen(title: "Map", hero: UsageBar(id: "root", title: "", segments: parts), widgets: [])
        let group = try XCTUnwrap(ScreenView.graphGroup(aggregate, usageID: "root"))
        XCTAssertEqual(ScreenView.row(group.id, in: screen)?.children.count, 120)
        XCTAssertNotEqual(group.id, ScreenView.graphGroup(aggregate, usageID: "child")?.id)
        XCTAssertEqual(ScreenView.row("folder:/17", in: screen)?.pageID, "folder:/17")
    }

    func testOtherFoldersOpensMapAndNestedMapsKeepActualDestinations() throws {
        let parts = [UsageSegment(id: "huge", label: "Huge", bytes: 1_000_000, tone: .series(0), pageID: "folder:/huge", kind: .folder),
                     UsageSegment(id: "medium", label: "Medium", bytes: 1000, tone: .series(1), pageID: "folder:/medium", kind: .folder),
                     UsageSegment(id: "tiny", label: "Tiny", bytes: 1, tone: .series(2), pageID: "folder:/tiny", kind: .folder),
                     UsageSegment(id: "files", label: "Other files", bytes: 4, tone: .series(3), pageID: "browse:files", kind: .files)]
        let screen = Screen(title: "Disk", hero: UsageBar(id: "root", title: "Disk", segments: parts), widgets: [])
        let aggregate = try XCTUnwrap(BlockLayout.blocks(parts).first { $0.segment.id == BlockLayout.foldersID }?.segment)
        let id = try XCTUnwrap(ScreenView.graphGroup(aggregate, usageID: "root")?.id)
        let map = try XCTUnwrap(ScreenView.graphPage(id, in: screen))
        XCTAssertTrue(map.widgets.isEmpty)
        XCTAssertEqual(Set(map.hero?.segments.compactMap(\.pageID) ?? []), ["folder:/medium", "folder:/tiny"])
        XCTAssertEqual(map.hero?.totalBytes, 1001)
        let child = try XCTUnwrap(ScreenView.graphBlocks(try XCTUnwrap(map.hero)).first { $0.segment.id == BlockLayout.foldersID }?.segment)
        let childID = try XCTUnwrap(ScreenView.graphGroup(child, usageID: id)?.id)
        let nested = try XCTUnwrap(ScreenView.graphPage(childID, in: map))
        XCTAssertNotEqual(id, childID)
        XCTAssertEqual(nested.hero?.segments.map(\.pageID), ["folder:/tiny"])
        XCTAssertEqual(nested.hero?.totalBytes, 1)
        XCTAssertEqual(ScreenView.row("browse:files", in: screen)?.pageID, "browse:files")
        XCTAssertNil(ScreenView.graphPage("browse:files", in: screen), "Other files keeps its module-supplied list")
    }

    func testEmptyFolderForestShowsDestinationsWithoutAnotherAggregate() throws {
        let folders = (0..<2).map { UsageSegment(id: "empty\($0)", label: "Empty", bytes: 0, tone: .series($0), pageID: "folder:/empty\($0)", kind: .folder) }
        let screen = Screen(title: "Disk", hero: UsageBar(id: "root", title: "", segments: folders), widgets: [])
        let aggregate = try XCTUnwrap(BlockLayout.blocks(folders).first?.segment)
        let id = try XCTUnwrap(ScreenView.graphGroup(aggregate, usageID: "root")?.id)
        let map = try XCTUnwrap(ScreenView.graphPage(id, in: screen))
        XCTAssertEqual(ScreenView.graphBlocks(try XCTUnwrap(map.hero)).map { $0.segment }, folders)
    }

    func testSingleTinyFolderIsNotDroppedAndSemanticSmallerTilesKeepTheirFiles() throws {
        let parts = [UsageSegment(id: "big", label: "Big", bytes: 1_000_000, tone: .series(0), pageID: "folder:/big", kind: .folder),
                     UsageSegment(id: "tiny", label: "Tiny", bytes: 1, tone: .series(1), pageID: "folder:/tiny", kind: .folder)]
        XCTAssertEqual(BlockLayout.blocks(parts).first { $0.segment.id == BlockLayout.foldersID }?.segment.items.first?.pageID, "folder:/tiny")
        let semantic = [UsageSegment(id: "big", label: "Big", bytes: 1_000_000, tone: .series(0)),
                        UsageSegment(id: "one", label: "One", bytes: 1, tone: .series(1), items: [Row(id: "file1", title: "File one", paths: ["/one"])]),
                        UsageSegment(id: "two", label: "Two", bytes: 2, tone: .series(2), items: [Row(id: "file2", title: "File two", paths: ["/two"])])]
        let aggregate = try XCTUnwrap(BlockLayout.blocks(semantic).first { $0.segment.id == BlockLayout.smallerID }?.segment)
        XCTAssertEqual(Set(aggregate.group?.children.map(\.id) ?? []), ["file1", "file2"])
        XCTAssertEqual(aggregate.bytes, 3)
        let selection = Selection(action: Action(id: "freeFiles", title: "Free selected"), choices: ["file1": 1, "file2": 2], scope: "folder:root", partial: true)
        let choosing = try XCTUnwrap(ScreenView.graphGroup(aggregate, usageID: "root", selection: selection))
        XCTAssertEqual(choosing.selection?.choices, selection.choices)
        XCTAssertEqual(choosing.selection?.scope, selection.scope)
        let empty = UsageSegment(id: "empty", label: "Empty", bytes: 0, tone: .series(0), pageID: "folder:/empty", kind: .folder)
        XCTAssertEqual(BlockLayout.blocks([empty]).first?.segment.items.first?.pageID, "folder:/empty")
    }

    func testCollidingLegacyRowIDsKeepTheirOriginalGroupDestinations() throws {
        let a = UsageSegment(id: "a", label: "A", bytes: 1, tone: .series(1), items: [Row(id: "same", title: "One")])
        let b = UsageSegment(id: "b", label: "B", bytes: 2, tone: .series(2), items: [Row(id: "same", title: "Two")])
        let aggregate = BlockLayout.aggregate([a, b], folders: false)
        XCTAssertEqual(Set(aggregate.items.map(\.id)), ["segment:a", "segment:b"])
        XCTAssertEqual(Set(aggregate.items.flatMap(\.children).map(\.title)), ["One", "Two"])
    }

    func testGraphFilesOwnTheirSelectionWithoutAHiddenOverviewSelection() throws {
        let action = Action(id: "freeFiles", title: "Free selected")
        let files = (0..<2).map { n in
            UsageSegment(id: "part\(n)", label: "File \(n)", bytes: 1, tone: .series(n), items: [Row(id: "file\(n)", title: "File \(n)")],
                         selection: Selection(action: action, choices: ["file\(n)": 1], scope: "graph-files:root", partial: true))
        }
        let aggregate = BlockLayout.aggregate(files, folders: false)
        let screen = Screen(title: "Disk", hero: UsageBar(id: "disk", title: "Disk", segments: files), widgets: [])
        XCTAssertNil(screen.selection)
        XCTAssertEqual(aggregate.group?.selection?.choices.count, 2)
        XCTAssertEqual(ScreenView.graphGroup(aggregate, usageID: "disk")?.selection?.scope, "graph-files:root")
        XCTAssertEqual(try JSONDecoder().decode(UsageSegment.self, from: JSONEncoder().encode(aggregate)), aggregate)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(aggregate)) as? [String: Any])
        old.removeValue(forKey: "selection"); old.removeValue(forKey: "kind")
        let legacy = try JSONDecoder().decode(UsageSegment.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(legacy.selection)
    }

    func testDashboardLimitKeepsSeparateFolderAndFileDestinations() {
        let folders = (0..<8).map { UsageSegment(id: "dir\($0)", label: "Folder", bytes: UInt64(100 - $0), tone: .series($0), pageID: "folder:/\($0)", kind: .folder) }
        let files = UsageSegment(id: "files", label: "Other files", bytes: 9, tone: .series(0), pageID: "browse:files", kind: .files)
        let blocks = BlockLayout.blocks(folders + [files], limit: 4)
        XCTAssertLessThanOrEqual(blocks.count, 4)
        XCTAssertTrue(blocks.contains { $0.segment.id == "files" })
        let destinations = blocks.flatMap { $0.segment.pageID.map { [$0] } ?? $0.segment.items.compactMap(\.pageID) }
        XCTAssertEqual(Set(destinations), Set((folders + [files]).compactMap(\.pageID)))
        XCTAssertEqual(blocks.reduce(UInt64(0)) { $0 + $1.segment.bytes }, (folders + [files]).reduce(0) { $0 + $1.bytes })
    }
}
