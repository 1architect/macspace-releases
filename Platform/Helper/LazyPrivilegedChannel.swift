import Foundation
import MacSpaceSdk
import ServiceManagement

/// The channel modules receive. It connects to the helper on first use, and says plainly when the helper is not installed
/// or not approved yet instead of failing inside XPC.
public final class LazyPrivilegedChannel: PrivilegedChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var client: (any PrivilegedChannel)?
    private let status: @Sendable () -> SMAppService.Status
    private let makeClient: @Sendable () -> any PrivilegedChannel

    public init(status: @escaping @Sendable () -> SMAppService.Status = { PrivilegedHelperInstaller.status },
                makeClient: @escaping @Sendable () -> any PrivilegedChannel = { PrivilegedHelperClient() }) {
        self.status = status
        self.makeClient = makeClient
    }

    public func perform(operation: String, arguments: [String: String]) async throws -> Data {
        switch status() {
        case .enabled: break
        case .requiresApproval:
            throw PrivilegedHelperError.connection("the helper is installed but not approved yet; enable it in System Settings > General > Login Items & Extensions")
        case .notRegistered, .notFound:
            throw PrivilegedHelperError.connection("the helper is not installed; install it from MACSPACE Settings")
        @unknown default:
            throw PrivilegedHelperError.connection("the helper's state is unknown")
        }
        do {
            return try await connectedClient().perform(operation: operation, arguments: arguments)
        } catch PrivilegedHelperError.connection {
            // A connection that failed stays dead (the helper may have been restarted or loaded after the first try), so the next
            // attempt must start a new one.
            forgetClient()
            return try await connectedClient().perform(operation: operation, arguments: arguments)
        }
    }

    private func connectedClient() -> any PrivilegedChannel {
        lock.lock()
        defer { lock.unlock() }
        if client == nil { client = makeClient() }
        return client!
    }

    private func forgetClient() {
        lock.lock()
        client = nil
        lock.unlock()
    }
}
