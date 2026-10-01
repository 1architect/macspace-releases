import Foundation
import MacSpaceSdk

final class HelperExportedObject: NSObject, MacSpaceHelperProtocol {
    private let service: PrivilegedHelperService
    private let clientUID: uid_t

    init(service: PrivilegedHelperService, clientUID: uid_t) {
        self.service = service
        self.clientUID = clientUID
    }

    func perform(_ request: Data, withReply reply: @escaping (Data) -> Void) {
        let response: HelperResponse
        do {
            response = service.handle(try HelperCoding.decoder.decode(HelperRequest.self, from: request), clientUID: clientUID)
        } catch {
            response = HelperResponse(error: "Malformed request: \(error)")
        }
        reply((try? HelperCoding.encoder.encode(response)) ?? Data())
    }
}

/// Accepts connections that satisfy the code-signing requirement. A nil requirement accepts any client and is only for
/// in-process tests; the helper executable refuses to start without one.
public final class PrivilegedHelperListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let service: PrivilegedHelperService
    private let clientRequirement: String?

    public init(service: PrivilegedHelperService, clientRequirement: String?) {
        self.service = service
        self.clientRequirement = clientRequirement
    }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        if let clientRequirement { connection.setCodeSigningRequirement(clientRequirement) }
        connection.exportedInterface = NSXPCInterface(with: MacSpaceHelperProtocol.self)
        connection.exportedObject = HelperExportedObject(service: service, clientUID: connection.effectiveUserIdentifier)
        connection.resume()
        return true
    }
}

/// XPC may call both the reply and the error handler; resume the continuation only once.
private final class ResumeOnce: @unchecked Sendable {
    private var continuation: CheckedContinuation<Data, Error>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<Data, Error>) { self.continuation = continuation }

    private func take() -> CheckedContinuation<Data, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let taken = continuation
        continuation = nil
        return taken
    }

    func resume(returning data: Data) { take()?.resume(returning: data) }
    func resume(throwing error: Error) { take()?.resume(throwing: error) }
}

/// The app's side: carries operations to the helper and hands the result back. Conforms to the SDK's `PrivilegedChannel`,
/// which is what modules see.
public final class PrivilegedHelperClient: PrivilegedChannel, @unchecked Sendable {
    private let connection: NSXPCConnection

    /// Connects to the installed helper's Mach service.
    public init(machServiceName: String = PrivilegedHelperConstants.machServiceName) {
        connection = NSXPCConnection(machServiceName: machServiceName, options: .privileged)
        configure()
    }

    /// Connects to a listener endpoint (in-process tests).
    public init(endpoint: NSXPCListenerEndpoint) {
        connection = NSXPCConnection(listenerEndpoint: endpoint)
        configure()
    }

    private func configure() {
        connection.remoteObjectInterface = NSXPCInterface(with: MacSpaceHelperProtocol.self)
        connection.resume()
    }

    deinit { connection.invalidate() }

    public func perform(operation: String, arguments: [String: String]) async throws -> Data {
        let payload = try HelperCoding.encoder.encode(HelperRequest(operation: operation, arguments: arguments))
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                once.resume(throwing: PrivilegedHelperError.connection(error.localizedDescription))
            }) as? MacSpaceHelperProtocol else {
                once.resume(throwing: PrivilegedHelperError.connection("no remote proxy"))
                return
            }
            proxy.perform(payload) { once.resume(returning: $0) }
        }
        guard let response = try? HelperCoding.decoder.decode(HelperResponse.self, from: data) else { throw PrivilegedHelperError.malformedResponse }
        if let error = response.error { throw PrivilegedHelperError.helper(error) }
        return response.payload ?? Data()
    }
}

public extension PrivilegedChannel {
    /// Calls an operation and decodes its JSON result.
    func perform<Result: Decodable>(_ type: Result.Type, operation: String, arguments: [String: String] = [:]) async throws -> Result {
        let data = try await perform(operation: operation, arguments: arguments)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Result.self, from: data)
    }
}
