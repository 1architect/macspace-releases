import Foundation

/// Read-only access to assetsubscriptiond's UAF subscription database (world-readable, opened `immutable=1`).
public enum UAFSubscriptionDatabase {
    public static let path = "/private/var/db/assetsubscriptiond/UAFAssetSubscriptions.db"

    public static func userGUID(uid: uid_t) -> String? {
        // <membership.h> is not in the Darwin module map.
        typealias UIDToUUID = @convention(c) (uid_t, UnsafeMutablePointer<UInt8>) -> Int32
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "mbr_uid_to_uuid") else { return nil }
        var bytes = [UInt8](repeating: 0, count: 16)
        guard unsafeBitCast(symbol, to: UIDToUUID.self)(uid, &bytes) == 0 else { return nil }
        return NSUUID(uuidBytes: bytes).uuidString
    }

    public static func query(_ path: String = path, _ sql: String) -> [[String: String]]? {
        guard FileManager.default.isReadableFile(atPath: path) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        let uri = "file:\(path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path)?mode=ro&immutable=1"
        process.arguments = ["-json", uri, sql]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        // sqlite3 prints nothing for an empty result.
        if data.allSatisfy({ $0 == 0x0A || $0 == 0x20 }) { return [] }
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return rows.map { row in
            row.compactMapValues { value in (value as? String) ?? (value as? NSNumber)?.stringValue }
        }
    }

    /// Runs a script against the live database (read-write). Needs root; used only by `OrphanSubscriptionCleaner`.
    public static func write(_ path: String, _ script: String) -> (status: Int32, message: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [path]
        let input = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        input.fileHandleForWriting.write(Data(script.utf8))
        try? input.fileHandleForWriting.close()
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, message.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
