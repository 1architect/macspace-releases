import Foundation
import XCTest
import MacSpaceDiskMapPrivileged
@testable import MacSpaceDiskMap

final class DiskOwnershipQueryTests: DiskSecurityFixtureCase {
    func testOneAncestorQueryRetainsLeastCertainEvidenceAndRepeatedRelations() throws {
        let base = URL(fileURLWithPath: "/private/tmp/ownership-query-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("home/Downloads").path
        let db = try DiskDatabase(url: base.appendingPathComponent("cache/index.sqlite"), root: root, home: base.appendingPathComponent("home").path)
        let parent = root + "/folder", path = parent + "/file.txt"
        let rootClaim = DiskOwnershipClaim(paths: [root, parent], ownerPaths: ["/Applications/A.app"], confidence: .verifiedExclusive, source: "root", reason: "Root evidence")
        let childClaim = DiskOwnershipClaim(paths: [path], ownerPaths: ["/Applications/B.app"], confidence: .unknown, source: "child", reason: "Uncertain child")
        let encoder = JSONEncoder()
        for (offset, claim) in [rootClaim, childClaim].enumerated() {
            let id = UInt64(offset + 1)
            try db.query("INSERT INTO claims(id,data) VALUES(?,?)", [.number(id), .data(try encoder.encode(claim))])
            for held in claim.paths { try db.query("INSERT INTO ownership VALUES(?,?)", [.text(held), .number(id)]) }
        }
        XCTAssertEqual(try db.ownershipEvidence(path), DiskOwnership.combined([rootClaim, rootClaim, childClaim], paths: [path]))
        XCTAssertEqual(try db.ownershipEvidence(parent), DiskOwnership.combined([rootClaim, rootClaim], paths: [parent]))
        XCTAssertEqual(try db.ownershipEvidence(root), rootClaim)
        XCTAssertEqual(try db.ownershipEvidence(root + "/unclaimed.txt"), rootClaim)
        XCTAssertNil(try db.ownershipEvidence(root + "-other/file.txt"))
        XCTAssertNil(try db.ownershipEvidence(parent + "/../file.txt"))
    }
}
