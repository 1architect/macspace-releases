import Darwin
import XCTest
@testable import MacSpaceSiri

final class SiriSavedSettingsMigrationTests: XCTestCase {
    private func fixture(_ body: (URL) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try body(folder.appendingPathComponent("saved.json"))
    }
    func testOwnerWrittenLegacySettingsMigrateWithoutLosingRestorationData() throws {
        try fixture { url in
            let saved = SavedSiriSettings(siriLanguage: "pt-BR", outputVoice: Data([1, 2, 3]), savedAt: Date(timeIntervalSince1970: 1_700_000_000))
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            let original = try encoder.encode(saved)
            try original.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            let environment = LiveSiriLanguageEnvironment(savedSettingsURL: url)
            XCTAssertEqual(try environment.loadSavedSettings(), saved)
            XCTAssertEqual(try Data(contentsOf: url), original)
            var info = stat(); XCTAssertEqual(lstat(url.path, &info), 0); XCTAssertEqual(info.st_mode & 0o777, 0o600)
            try environment.saveSettings(nil)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }
    func testUnsafeOrCorruptRecoveryStateIsAnErrorInsteadOfMissingState() throws {
        try fixture { url in
            let environment = LiveSiriLanguageEnvironment(savedSettingsURL: url)
            XCTAssertNil(try environment.loadSavedSettings())
            try Data("invalid".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: url.path)
            XCTAssertThrowsError(try environment.loadSavedSettings())
            var info = stat(); XCTAssertEqual(lstat(url.path, &info), 0); XCTAssertEqual(info.st_mode & 0o777, 0o666)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            XCTAssertThrowsError(try environment.loadSavedSettings())
            XCTAssertEqual(try Data(contentsOf: url), Data("invalid".utf8))
        }
    }
    func testLinkedLegacySettingsCannotBeMigrated() throws {
        try fixture { url in
            let target = url.appendingPathExtension("target")
            try Data("preserved".utf8).write(to: target)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
            XCTAssertThrowsError(try LiveSiriLanguageEnvironment(savedSettingsURL: url).loadSavedSettings())
            var info = stat(); XCTAssertEqual(lstat(target.path, &info), 0); XCTAssertEqual(info.st_mode & 0o777, 0o644)
            XCTAssertEqual(try Data(contentsOf: target), Data("preserved".utf8))
        }
    }
}
