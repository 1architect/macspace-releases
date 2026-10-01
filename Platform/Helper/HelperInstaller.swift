import Foundation
import MacSpaceSdk
import ServiceManagement

/// Registers the helper launch daemon that ships in the app bundle (`Contents/Library/LaunchDaemons/com.macspace.helper.plist`,
/// program `Contents/MacOS/MacSpaceHelper`). Only meaningful from the signed app; the user approves it once in System Settings
/// > General > Login Items & Extensions.
public enum PrivilegedHelperInstaller {
    public static var service: SMAppService { .daemon(plistName: PrivilegedHelperConstants.launchDaemonPlistName) }

    public static var status: SMAppService.Status { service.status }

    /// What the Settings page shows for the "Privileged helper" permission.
    public static func permissionStatus(_ status: SMAppService.Status = PrivilegedHelperInstaller.status) -> PermissionStatus {
        switch status {
        case .enabled: return .granted
        case .notRegistered, .requiresApproval: return .missing
        case .notFound: return .unknown
        @unknown default: return .unknown
        }
    }

    /// Registers the daemon. `.requiresApproval` afterwards means the user must enable it in Login Items.
    public static func register() throws { try service.register() }

    public static func unregister() async throws { try await service.unregister() }

    /// After an app update the old helper process keeps running until it is restarted, so it would not know new operations. The
    /// helper reports the fingerprint of the binary it started from; when that differs from the binary in this app, the helper
    /// is unregistered and registered again, which starts the new one. Returns whether it was restarted.
    @discardableResult
    public static func restartIfStale(channel: any PrivilegedChannel, bundle: Bundle = .main) async -> Bool {
        guard status == .enabled, let helperPath = bundle.executableURL?.deletingLastPathComponent().appendingPathComponent("MacSpaceHelper").path,
              let onDisk = HelperFingerprint.of(path: helperPath),
              let data = try? await channel.perform(operation: PrivilegedHelperService.pingOperation, arguments: [:]) else { return false }
        let running = String(decoding: data, as: UTF8.self)
        guard running != onDisk else { return false }
        do { try await unregister() } catch { return false }
        // Registering straight after unregistering can fail while launchd is still removing the job: retry briefly.
        for attempt in 0..<6 {
            do { try register(); return true } catch {
                if attempt == 5 { return false }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        return false
    }

    public static func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }
}
