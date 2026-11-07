import XCTest
import Security
import CryptoKit
import LocalAuthentication
@testable import MacSpacePlatform

private final class MemoryMetadataStore: MetadataKeyStore, @unchecked Sendable {
    let lock = NSLock()
    var data: [String: Data] = [:]
    func read(_ account: String) throws -> Data? { lock.withLock { data[account] } }
    func create(_ account: String, value: Data) throws { try lock.withLock { guard data[account] == nil else { throw MetadataUnavailable() }; data[account] = value } }
    func replace(_ account: String, value: Data) throws { lock.withLock { data[account] = value } }
    func delete(_ account: String) throws { _ = lock.withLock { data.removeValue(forKey: account) } }
}
final class MetadataSecurityTests: XCTestCase {
    func testEveryKeychainLifecycleCallIsExplicitlyNoninteractive() throws {
        let store = SilentMetadataKeyStore(accessGroup: { "TEST.com.macspace.metadata" }) { operation, query, values in
            XCTAssertEqual((query[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed, true)
            XCTAssertEqual(query[kSecUseDataProtectionKeychain as String] as? Bool, true)
            XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, false)
            XCTAssertEqual(query[kSecAttrAccessGroup as String] as? String, "TEST.com.macspace.metadata")
            if operation == "create" { XCTAssertEqual(query[kSecAttrAccessible as String] as? String, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String) }
            return (errSecInteractionNotAllowed, nil)
        }
        XCTAssertThrowsError(try store.read("key")); XCTAssertThrowsError(try store.create("key", value: Data(repeating: 1, count: 32)))
        XCTAssertThrowsError(try store.replace("key", value: Data())); XCTAssertThrowsError(try store.delete("key"))
    }
    func testRecordAuthenticationBindsPurposeAndKey() throws {
        let key = Data(repeating: 42, count: 32), plain = Data("sensitive-path-seed".utf8)
        let sealed = try EncryptedMetadata.seal(plain, key: key, context: "scope-a")
        XCTAssertNil(sealed.range(of: plain)); XCTAssertEqual(try EncryptedMetadata.open(sealed, key: key, context: "scope-a"), plain)
        XCTAssertThrowsError(try EncryptedMetadata.open(sealed, key: key, context: "scope-b"))
        XCTAssertThrowsError(try EncryptedMetadata.open(sealed, key: Data(repeating: 3, count: 32), context: "scope-a"))
        var corrupt = sealed; corrupt[12] ^= 1
        XCTAssertThrowsError(try EncryptedMetadata.open(corrupt, key: key, context: "scope-a"))
    }
    func testJournalRejectsOldValidCiphertextAndPreservesIt() throws {
        MetadataKeys.useStore(MemoryMetadataStore()); defer { MetadataKeys.useStore(SilentMetadataKeyStore()) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("record.sealed")
        let journal = try ProtectedJournal(url: url, purpose: UUID().uuidString, allowKeyCreation: true)
        try journal.write(Data("first".utf8)); let old = try Data(contentsOf: url)
        try journal.write(Data("second".utf8)); XCTAssertEqual(try journal.read(), Data("second".utf8))
        try PrivateFile(url).write(old)
        XCTAssertThrowsError(try journal.read()); XCTAssertEqual(try Data(contentsOf: url), old)
    }
    func testPrivateFilesRejectRootReplacementAndSymlinkTargets() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder); try? FileManager.default.removeItem(atPath: folder.path + "-old") }
        let url = folder.appendingPathComponent("state"), boundary = try PrivateFile(url)
        try boundary.write(Data("old".utf8))
        try FileManager.default.moveItem(atPath: folder.path, toPath: folder.path + "-old")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertThrowsError(try boundary.write(Data("new".utf8)))
        let target = folder.appendingPathComponent("target"); try Data("preserved".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        XCTAssertThrowsError(try PrivateFile(url).write(Data("changed".utf8)))
        XCTAssertEqual(try Data(contentsOf: target), Data("preserved".utf8))
    }
}
final class BoundedCommandSecurityTests: XCTestCase {
    func testOutputFloodIsCappedAndCannotBeParsedAsSuccess() {
        let result = BoundedCommand.run("/usr/bin/head", arguments: ["-c", "2097152", "/dev/zero"], environment: [:], timeout: 5)
        XCTAssertTrue(result.truncated); XCTAssertEqual(result.stdout.count, 1_048_576); XCTAssertNotEqual(result.status, 0)
    }
    func testTimeoutIncludesInheritedPipesAndIgnoredTermination() {
        for command in ["trap '' TERM; while :; do :; done", "sleep 1 &"] {
            let start = Date()
            let result = BoundedCommand.run("/bin/sh", arguments: ["-c", command], environment: ["PATH": "/usr/bin:/bin"], timeout: 0.3)
            XCTAssertTrue(result.timedOut); XCTAssertEqual(result.status, -2); XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        }
    }
}

extension MetadataSecurityTests {
    func testInterruptedJournalWritesReconcileOnlyProtectedCheckpointVersions() throws {
        let memory = MemoryMetadataStore()
        MetadataKeys.useStore(memory); defer { MetadataKeys.useStore(SilentMetadataKeyStore()) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        for completeFileWrite in [false, true] {
            let purpose = UUID().uuidString, name = "recovery.v2." + purpose
            let url = folder.appendingPathComponent(purpose)
            let journal = try ProtectedJournal(url: url, purpose: purpose, allowKeyCreation: true)
            try journal.write(Data("original".utf8))
            let old = try Data(contentsOf: url)
            let key = try MetadataKeys.key(.recovery, create: false)
            let next = try EncryptedMetadata.seal(Data("next".utf8), key: key, context: name + ":" + String(getuid()))
            struct Checkpoint: Codable { let current: Data; let pending: Data }
            try MetadataKeys.checkpoint(name, value: JSONEncoder().encode(Checkpoint(current: Data(SHA256.hash(data: old)), pending: Data(SHA256.hash(data: next)))))
            if completeFileWrite { try PrivateFile(url).write(next) }
            let reopened = try ProtectedJournal(url: url, purpose: purpose, allowKeyCreation: false)
            XCTAssertEqual(try reopened.read(), Data((completeFileWrite ? "next" : "original").utf8))
        }
    }
    func testMissingRecoveryKeyNeverReplacesOrOverwritesTheJournal() throws {
        let memory = MemoryMetadataStore()
        MetadataKeys.useStore(memory); defer { MetadataKeys.useStore(SilentMetadataKeyStore()) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("record"), purpose = UUID().uuidString
        let journal = try ProtectedJournal(url: url, purpose: purpose, allowKeyCreation: true)
        try journal.write(Data("recovery".utf8)); let original = try Data(contentsOf: url)
        try memory.delete("key.recovery." + String(getuid()))
        XCTAssertThrowsError(try ProtectedJournal(url: url, purpose: purpose, allowKeyCreation: false))
        XCTAssertThrowsError(try journal.write(Data("replacement".utf8)))
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertNil(try memory.read("key.recovery." + String(getuid())))
    }
    func testLateNativeRepliesCannotChangeAnAlreadyTimedOutReply() {
        let reply = AssetOwners.Reply<String>()
        XCTAssertFalse(reply.wait(0))
        reply.send("late")
        XCTAssertNil(reply.value)
        let completed = AssetOwners.Reply<String>(); completed.send("first"); completed.send("second")
        XCTAssertTrue(completed.wait(0)); XCTAssertEqual(completed.value, "first")
    }
}
