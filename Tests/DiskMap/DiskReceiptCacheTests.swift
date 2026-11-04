import XCTest
import MacSpaceDiskMapPrivileged
@testable import MacSpaceDiskMap

final class DiskReceiptCacheTests: XCTestCase {
    func testHistoricalReceiptsRoundTripWithoutSerializingAnyAppRemovalPlan() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let url = base.appendingPathComponent("receipts.json")
        var receipts = AppReceiptCatalog()
        receipts.manifests = [.init(identifier: "fixture", paths: ["/Applications/Fixture.app/Contents/file"], complete: false, reason: "Historical evidence")]
        DiskReceiptCache.save(receipts, to: url)
        XCTAssertEqual(DiskReceiptCache.read(url), receipts)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["version", "receipts"])
        XCTAssertNil(object["apps"]); XCTAssertNil(object["plan"])
        try Data("invalid".utf8).write(to: url)
        XCTAssertNil(DiskReceiptCache.read(url))
    }
    func testNewInventorySeedsOnlyReceiptsAndForcedReviewBypassesThem() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let url = base.appendingPathComponent("receipts.json")
        var receipts = AppReceiptCatalog()
        receipts.manifests = [.init(identifier: "fixture", paths: [], complete: false, reason: "Historical evidence")]
        DiskReceiptCache.save(receipts, to: url)
        let inventory = DiskInventory(receiptCache: url, loader: { _, previous in
            XCTAssertTrue(previous?.apps.isEmpty ?? true)
            XCTAssertTrue(previous?.apps.allSatisfy { $0.plan == nil } ?? true)
            return previous ?? DiskApplications()
        })
        var index = DiskIndex(root: "/"); index.catalogRevision = 42; index.revision = 1
        let cached = await inventory.read(index)
        XCTAssertEqual(cached.receipts.manifests.count, 1)
        let forced = await inventory.read(index, force: true)
        XCTAssertTrue(forced.receipts.manifests.isEmpty)
    }
}
