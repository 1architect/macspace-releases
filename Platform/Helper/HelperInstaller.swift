import CoreServices
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

    /// Tells Launch Services about this app. A copy that arrived without Launch Services noticing (a shared folder, a VM, a manual
    /// copy) leaves the helper "not found" and registering fails; once the app is registered, the status becomes "requires approval".
    public static func registerAppWithLaunchServices(bundle: Bundle = .main) {
        _ = LSRegisterURL(bundle.bundleURL as CFURL, true)
    }

    public struct NotInApplicationsError: LocalizedError {
        public let path: String
        public var errorDescription: String? {
            "MacSpace runs from \(path). Install the helper from the copy in an Applications folder: macOS ties the helper to the copy it was installed from, and a build folder is replaced by every build."
        }
    }

    /// Whether the app sits in an Applications folder (/Applications or ~/Applications), the only place the helper is installed from.
    public static func isInApplicationsFolder(_ path: String) -> Bool {
        path.hasPrefix("/Applications/") || path.contains("/Applications/")
    }

    /// Registers the daemon. `.requiresApproval` afterwards means the user must enable it in Login Items. Refused from a copy outside
    /// an Applications folder: registered from the build folder, the helper stayed tied to that copy, every build replaced it, and
    /// installing from the real copy failed with "Codesigning failure loading plist" (-67056).
    public static func register(bundle: Bundle = .main) throws {
        guard isInApplicationsFolder(bundle.bundlePath) else { throw NotInApplicationsError(path: bundle.bundlePath) }
        if status == .notFound { registerAppWithLaunchServices() }
        try service.register()
    }

    public static func unregister() async throws { try await service.unregister() }

    /// At launch: makes the helper ready without the user having to press anything, and without ever costing them its approval.
    ///
    /// - An approved helper is only pinged, a few times over about twenty seconds: after an update the helper of the earlier build
    ///   steps down (`HelperLifecycle`) and launchd starts the new one on a later request, at most every ten seconds. It is never
    ///   registered again: unregistering and registering drops the approval, and the app used to do that whenever the helper did not
    ///   answer within ten seconds of an update, which sent the user back to "Install helper" after updates (2026-10-05).
    /// - A helper that is not registered (first launch, or macOS dropped it) is registered by itself from an intact copy in an
    ///   Applications folder; macOS then asks for the approval once if it needs it.
    /// - Nothing is registered from a damaged copy (`CodeIntegrity`): macOS ties the helper to the copy's signature.
    /// Returns whether it registered the helper.
    @discardableResult
    public static func ensureAtLaunch(channel: any PrivilegedChannel, bundle: Bundle = .main,
                                      waits: [Double] = [0, 2, 5, 12]) async -> Bool {
        guard isInApplicationsFolder(bundle.bundlePath), CodeIntegrity.isIntact(bundle.bundleURL) else { return false }
        switch status {
        case .enabled:
            for wait in waits {
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
                if (try? await channel.perform(operation: PrivilegedHelperService.pingOperation, arguments: [:])) != nil { break }
            }
            return false
        case .notRegistered, .notFound:
            do { try register(bundle: bundle) } catch { return status == .requiresApproval }
            return true
        default:
            return false
        }
    }

    /// Why macOS reports the helper as "not found", worded for the Settings page. The usual cause is a quarantined app: macOS runs it
    /// from a randomized, read-only copy (App Translocation) and the helper cannot be registered from there.
    public static func notFoundReason(bundlePath: String, quarantined: Bool, containsLaunchDaemon: Bool) -> String {
        if !containsLaunchDaemon { return "This build of MacSpace does not contain the helper." }
        if bundlePath.contains("/AppTranslocation/") || quarantined {
            return "macOS is treating MacSpace as a downloaded app, so the helper cannot be installed. In Terminal run: xattr -dr com.apple.quarantine /Applications/MacSpace.app, then reopen MacSpace. (A notarized release does not need this.)"
        }
        if !isInApplicationsFolder(bundlePath) { return "Move MacSpace to the Applications folder, then reopen it." }
        return "Press Install helper. If macOS still does not recognise it, run in Terminal: /Applications/MacSpace.app/Contents/MacOS/MacSpaceCli helper --register and send the message it prints."
    }

    public static func notFoundReason(bundle: Bundle = .main) -> String {
        let path = bundle.bundlePath
        let quarantined = getxattr(path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0
        let plist = bundle.bundleURL.appendingPathComponent("Contents/Library/LaunchDaemons/\(PrivilegedHelperConstants.launchDaemonPlistName)").path
        return notFoundReason(bundlePath: path, quarantined: quarantined, containsLaunchDaemon: FileManager.default.fileExists(atPath: plist))
    }

    public static func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }
}
