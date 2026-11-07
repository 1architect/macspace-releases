import AppKit
import CoreGraphics
import Foundation

/// Observes session locking without authentication APIs or UI. Keys are never cached here.
public final class MetadataSession: @unchecked Sendable {
    public static let shared = MetadataSession()
    private let lock = NSLock()
    private let gate = MetadataSessionGate {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              (session[kCGSessionUserIDKey as String] as? NSNumber)?.uint32Value == getuid() else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool != true && session[kCGSessionOnConsoleKey as String] as? Bool == true
    }
    private var callbacks: [UUID: @Sendable () -> Void] = [:]
    private var tokens: [NSObjectProtocol] = []
    private init() {
        let center = DistributedNotificationCenter.default()
        tokens.append(center.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: nil) { [weak self] _ in self?.setLocked(true) })
        tokens.append(center.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: nil) { [weak self] _ in self?.setLocked(false) })
        tokens.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: nil) { [weak self] _ in self?.setLocked(true) })
        tokens.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in self?.setLocked(false) })
    }
    /// Keychain lifecycle calls always query the current session before the OS key operation.
    public var available: Bool { gate.available(fresh: true) }
    /// High-frequency SQL work uses notifications plus a 100 ms fallback probe.
    public var allowsProtectedWork: Bool { gate.available() }
    private func setLocked(_ value: Bool) {
        gate.setLocked(value)
        let pending = lock.withLock { value ? Array(callbacks.values) : [] }
        pending.forEach { $0() }
    }
    public final class Observation: @unchecked Sendable {
        private let id: UUID
        fileprivate init(_ id: UUID) { self.id = id }
        deinit { MetadataSession.shared.remove(id) }
    }
    public func onLock(_ callback: @escaping @Sendable () -> Void) -> Observation {
        let id = lock.withLock { let id = UUID(); callbacks[id] = callback; return id }
        return Observation(id)
    }
    public func remove(_ id: UUID) { _ = lock.withLock { callbacks.removeValue(forKey: id) } }
}
