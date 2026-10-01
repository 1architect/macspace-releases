import Foundation

/// Routes helper requests to the handlers compiled into the helper. Independent of XPC, so it can be tested and reused.
/// Calls are serialized: handlers touch shared system state and are not written to run concurrently.
public final class PrivilegedHelperService: @unchecked Sendable {
    private let handlers: [String: any PrivilegedOperationHandler]
    private let queue = DispatchQueue(label: "com.macspace.helper.requests")

    /// Built-in operation that answers without any handler: lets the app check that the helper is up.
    public static let pingOperation = "helper.ping"

    public init(handlers: [any PrivilegedOperationHandler]) {
        var map: [String: any PrivilegedOperationHandler] = [:]
        for handler in handlers {
            for operation in handler.operations {
                precondition(map[operation] == nil && operation != Self.pingOperation, "duplicate privileged operation \(operation)")
                map[operation] = handler
            }
        }
        self.handlers = map
    }

    public var operations: [String] { (Array(handlers.keys) + [Self.pingOperation]).sorted() }

    public func handle(_ request: HelperRequest, clientUID: uid_t) -> HelperResponse {
        queue.sync {
            guard request.protocolVersion == PrivilegedHelperConstants.protocolVersion else {
                return HelperResponse(error: "Protocol version \(request.protocolVersion) is not supported; the helper speaks \(PrivilegedHelperConstants.protocolVersion).")
            }
            if request.operation == Self.pingOperation { return HelperResponse() }
            guard let handler = handlers[request.operation] else { return HelperResponse(error: "Unknown operation \(request.operation).") }
            do {
                return HelperResponse(payload: try handler.handle(request.operation, arguments: request.arguments, caller: PrivilegedCaller(uid: clientUID)))
            } catch {
                return HelperResponse(error: error.localizedDescription)
            }
        }
    }
}
