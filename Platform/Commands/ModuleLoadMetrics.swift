import Foundation

/// Opt-in backend timings. Only phase names and durations are emitted; file paths and snapshot contents are never logged.
public enum ModuleLoadMetrics {
    private static let enabled = ProcessInfo.processInfo.environment["MACSPACE_LOAD_METRICS"] == "1"
    private static let lock = NSLock()
    private static let file: FileHandle? = {
        guard enabled, let path = ProcessInfo.processInfo.environment["MACSPACE_LOAD_METRICS_FILE"] else { return nil }
        _ = FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }()

    public static func measure<Value>(_ module: String, _ phase: String, _ work: () -> Value) -> Value {
        guard enabled else { return work() }
        let started = Date()
        defer {
            let data = Data("MODULE_STAGE module=\(module) phase=\(phase) seconds=\(Date().timeIntervalSince(started))\n".utf8)
            lock.withLock { FileHandle.standardError.write(data); file?.write(data) }
        }
        return work()
    }
}
