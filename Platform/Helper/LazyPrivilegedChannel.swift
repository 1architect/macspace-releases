import Foundation
import MacSpaceSdk
import ServiceManagement

/// The channel modules receive. It connects to the helper on first use, and says plainly when the helper is not installed
/// or not approved yet instead of failing inside XPC.
public final class LazyPrivilegedChannel: PrivilegedChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var client: (any PrivilegedChannel)?
    /// The client's helper answered a ping (`answering`).
    private var verified = false
    private let status: @Sendable () -> SMAppService.Status
    private let makeClient: @Sendable () -> any PrivilegedChannel

    public init(status: @escaping @Sendable () -> SMAppService.Status = { PrivilegedHelperInstaller.status },
                makeClient: @escaping @Sendable () -> any PrivilegedChannel = { PrivilegedHelperClient() },
                pingTimeout: TimeInterval = LazyPrivilegedChannel.defaultPingTimeout, health: HelperHealth = .shared) {
        self.status = status
        self.makeClient = makeClient
        self.pingTimeout = pingTimeout
        self.health = health
    }

    private let health: HelperHealth

    public func perform(operation: String, arguments: [String: String]) async throws -> Data {
        switch status() {
        case .enabled: break
        case .requiresApproval:
            throw PrivilegedHelperError.connection("the helper is installed but not approved yet; enable it in System Settings > General > Login Items & Extensions")
        case .notRegistered, .notFound:
            throw PrivilegedHelperError.connection("the helper is not installed; install it from MacSpace Settings")
        @unknown default:
            throw PrivilegedHelperError.connection("the helper's state is unknown")
        }
        if let silentUntil = silent(), Date() < silentUntil {
            throw PrivilegedHelperError.connection("the helper did not answer a moment ago; it is asked again in a minute")
        }
        do {
            return try await answering().perform(operation: operation, arguments: arguments)
        } catch PrivilegedHelperError.connection {
            // A connection that failed stays dead (the helper may have been restarted or loaded after the first try), so the next
            // attempt must start a new one.
            forgetClient()
            return try await answering().perform(operation: operation, arguments: arguments)
        }
    }

    /// How long a new connection's helper has to answer a ping. A helper launchd cannot start answers nothing at all; without the
    /// ping, every call waited for the full timeout before the page could show what it had.
    public static let defaultPingTimeout: TimeInterval = 8
    private let pingTimeout: TimeInterval
    /// How long the helper is not asked again after it gave no answer.
    static let silencePause: TimeInterval = 60
    private var silentUntil: Date?

    private func silent() -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return silentUntil
    }

    private func setSilent(until date: Date) {
        lock.lock()
        silentUntil = date
        lock.unlock()
    }

    /// The connected client, once its helper has answered a ping.
    private func answering() async throws -> any PrivilegedChannel {
        let (client, verified) = connectedClient()
        guard !verified else { return client }
        if let timed = client as? PrivilegedHelperClient {
            do {
                _ = try await timed.perform(operation: PrivilegedHelperService.pingOperation, arguments: [:], timeout: pingTimeout)
            } catch PrivilegedHelperError.noAnswer(let seconds) {
                // Every page that asks would wait as long again: the next calls fail at once until the pause is over.
                health.record(answered: false)
                forgetClient()
                setSilent(until: Date().addingTimeInterval(Self.silencePause))
                throw PrivilegedHelperError.noAnswer(seconds: seconds)
            }
        }
        health.record(answered: true)
        markVerified(client)
        return client
    }

    private func markVerified(_ verifiedClient: any PrivilegedChannel) {
        lock.lock()
        if let client, client as AnyObject === verifiedClient as AnyObject { verified = true }
        lock.unlock()
    }

    private func connectedClient() -> (client: any PrivilegedChannel, verified: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if let client { return (client, verified) }
        let made = makeClient()
        client = made
        verified = false
        return (made, false)
    }

    private func forgetClient() {
        lock.lock()
        client = nil
        verified = false
        lock.unlock()
    }
}
