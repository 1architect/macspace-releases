import Foundation

/// Routes helper requests to the handlers compiled into the helper. Independent of XPC, so it can be tested and reused.
/// Calls are serialized: handlers touch shared system state and are not written to run concurrently.
public final class PrivilegedHelperService: @unchecked Sendable {
    private let handlers: [String: any PrivilegedOperationHandler]
    private let queue = DispatchQueue(label: "com.macspace.helper.requests")

    /// Built-in operation that answers without any handler: lets the app check that the helper is up.
    public static let pingOperation = "helper.ping"

    /// Identity of the helper binary this process was started from; the app compares it with the binary on disk to notice that an
    /// update replaced the helper while the old one is still running.
    public let launchFingerprint: String

    public init(handlers: [any PrivilegedOperationHandler], launchFingerprint: String = HelperFingerprint.ofCurrentExecutable() ?? "") {
        self.launchFingerprint = launchFingerprint
        var map: [String: any PrivilegedOperationHandler] = [:]
        for handler in handlers {
            for operation in handler.operations {
                precondition(map[operation] == nil && operation != Self.pingOperation, "duplicate privileged operation \(operation)")
                map[operation] = handler
            }
        }
        self.handlers = map
    }

    /// Runs `body` once no operation is running (operations run one at a time on the service's queue).
    public func whenIdle(_ body: () -> Void) { queue.sync { body() } }

    public var operations: [String] { (Array(handlers.keys) + [Self.pingOperation]).sorted() }

    public func handle(_ request: HelperRequest, clientUID: uid_t) -> HelperResponse {
        queue.sync {
            guard request.protocolVersion == PrivilegedHelperConstants.protocolVersion else {
                return HelperResponse(error: "Protocol version \(request.protocolVersion) is not supported; the helper speaks \(PrivilegedHelperConstants.protocolVersion).")
            }
            if request.operation == Self.pingOperation { return HelperResponse(payload: Data(launchFingerprint.utf8)) }
            guard let handler = handlers[request.operation] else { return HelperResponse(error: "Unknown operation \(request.operation).") }
            do {
                return HelperResponse(payload: try handler.handle(request.operation, arguments: request.arguments, caller: PrivilegedCaller(uid: clientUID)))
            } catch {
                return HelperResponse(error: error.localizedDescription)
            }
        }
    }
}

/// Modification time and size of an executable: changes whenever an update replaces it.
public enum HelperFingerprint {
    public static func of(path: String) -> String? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return "\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)-\(info.st_size)"
    }

    public static func ofCurrentExecutable() -> String? { currentExecutablePath().flatMap(of(path:)) }

    public static func currentExecutablePath() -> String? {
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// The binary at `path` is no longer the one this process started from (the app was replaced). A missing file is not stale: the
    /// app may be in the middle of being copied.
    public static func isStale(launched: String, path: String) -> Bool {
        guard let now = of(path: path) else { return false }
        return now != launched
    }
}

/// The helper steps down by itself when the app around it was replaced, so launchd starts the new binary on the next request. This
/// keeps the user's approval: the app used to unregister and register the helper again to load a new one, and macOS then asked
/// for approval again, every time a new build was installed.
public enum HelperLifecycle {
    /// Checked on every new connection and every `interval` seconds; between requests, so no operation is cut off.
    public static func exitWhenReplaced(service: PrivilegedHelperService, interval: TimeInterval = 20) {
        guard let path = HelperFingerprint.currentExecutablePath() else { return }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { exitIfReplaced(service: service, path: path) }
        timer.resume()
        retained = timer
    }

    public static func exitIfReplaced(service: PrivilegedHelperService, path: String? = HelperFingerprint.currentExecutablePath()) {
        guard let path, HelperFingerprint.isStale(launched: service.launchFingerprint, path: path) else { return }
        service.whenIdle { exit(0) }
    }

    nonisolated(unsafe) private static var retained: DispatchSourceTimer?
}
