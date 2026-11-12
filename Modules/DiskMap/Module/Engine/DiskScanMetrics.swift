import Foundation
import OSLog

/// Opt-in backend diagnostics. No app window or diagnostic view is involved.
enum DiskScanMetrics {
    #if MACSPACE_DEV
    private static let logger = Logger(subsystem: "com.macspace", category: "LoadContinuity")
    #endif
    private static let enabled = ProcessInfo.processInfo.environment["MACSPACE_DISK_METRICS"] == "1"
    private static let lock = NSLock()
    private static let file: FileHandle? = {
        guard enabled, let path = ProcessInfo.processInfo.environment["MACSPACE_DISK_METRICS_FILE"] else { return nil }
        _ = FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }()
    static func write(_ message: String) {
        #if MACSPACE_DEV
        logger.notice("\(message, privacy: .public)")
        #endif
        guard enabled else { return }
        let data = Data((message + "\n").utf8)
        lock.withLock {
            FileHandle.standardError.write(data)
            file?.write(data)
        }
    }
    static func phase(_ name: String, since start: Date) {
        write("DISK_STAGE phase=\(name) seconds=\(Date().timeIntervalSince(start))")
    }
}
