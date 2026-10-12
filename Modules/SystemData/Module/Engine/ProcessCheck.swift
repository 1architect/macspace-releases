import Darwin
import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// One of the user's processes, as the cleaner sees it before a deletion.
public struct RunningProcess: Equatable, Sendable {
    public let pid: pid_t
    public let name: String
    public let executablePath: String?

    public init(pid: pid_t, name: String, executablePath: String?) {
        self.pid = pid
        self.name = name
        self.executablePath = executablePath
    }
}

/// What the cleaner checks before each deletion besides the running apps. The running apps miss what is not an app: a compiler using
/// its module cache, an app's helper or background agent, any process still holding a cache file open. The caches the cleaner deletes
/// belong to the user, so every process that can use them runs as the user and can be read without root. When something cannot be
/// read, the answer is unknown, and an unknown answer means the item is not deleted now.
public struct ProcessCheck: Sendable {
    /// The user's processes; nil when they cannot be listed.
    public var processes: @Sendable () -> [RunningProcess]?
    /// Whether one of the user's processes has a file, or its working folder, at or under one of the paths; nil when that cannot be
    /// told.
    public var holdsOpen: @Sendable (_ paths: [String]) -> Bool?
    /// Where the app with this bundle identifier is installed, so the processes running from inside it count as the app.
    public var appPath: @Sendable (_ bundleIdentifier: String) -> String?

    public init(processes: @escaping @Sendable () -> [RunningProcess]?, holdsOpen: @escaping @Sendable ([String]) -> Bool?,
                appPath: @escaping @Sendable (String) -> String?) {
        self.processes = processes
        self.holdsOpen = holdsOpen
        self.appPath = appPath
    }

    /// No processes and no open files: for tests that are about something else.
    public static let none = ProcessCheck(processes: { [] }, holdsOpen: { _ in false }, appPath: { _ in nil })

    public static let live = ProcessCheck(processes: liveProcesses, holdsOpen: liveHoldsOpen, appPath: liveAppPath)

    /// The first owner that is running: an app (by bundle identifier or name, `runningApps`' rule), a process with the owner's exact
    /// name (a command-line tool such as `clang`), or a process whose executable is inside the owner's app (its helpers and agents).
    static func runningOwner(_ owners: [String], apps: [RunningApp], processes: [RunningProcess], appPath: (String) -> String?) -> String? {
        owners.first { owner in
            if apps.contains(where: { app in
                app.bundleIdentifier?.caseInsensitiveCompare(owner) == .orderedSame
                    || app.name.map { $0.caseInsensitiveCompare(owner) == .orderedSame || owner.lowercased().contains($0.lowercased()) && $0.count >= 4 } == true
            }) { return true }
            if processes.contains(where: { $0.name.caseInsensitiveCompare(owner) == .orderedSame }) { return true }
            guard owner.contains("."), let bundle = appPath(owner) else { return false }
            let inside = bundle.hasSuffix("/") ? bundle : bundle + "/"
            return processes.contains { $0.executablePath?.hasPrefix(inside) == true }
        }
    }

    // MARK: Live

    static func userPIDs() -> [pid_t]? {
        let needed = proc_listpids(UInt32(PROC_UID_ONLY), getuid(), nil, 0)
        guard needed > 0 else { return nil }
        // Room for processes started between the two calls.
        var pids = [pid_t](repeating: 0, count: Int(needed) / MemoryLayout<pid_t>.size + 64)
        let filled = proc_listpids(UInt32(PROC_UID_ONLY), getuid(), &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return nil }
        return pids.prefix(Int(filled) / MemoryLayout<pid_t>.size).filter { $0 > 0 }
    }

    static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    @Sendable static func liveProcesses() -> [RunningProcess]? {
        guard let pids = userPIDs() else { return nil }
        return pids.compactMap { pid in
            var buffer = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
            let path = executablePath(pid)
            let name = proc_name(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : path.map { ($0 as NSString).lastPathComponent }
            // A process that ended between the listing and now has neither.
            return name.map { RunningProcess(pid: pid, name: $0, executablePath: path) }
        }
    }

    /// Apple's own programs on the sealed system. Some of them refuse to show their open files even to their own user (`lsd`,
    /// `nsurlsessiond`, `routined` on 27.2); they do not use third-party apps' caches, which are the only caches the cleaner deletes
    /// (Apple's are left to macOS), so their refusal does not make the answer unknown.
    static func isAppleSystemProgram(_ path: String?) -> Bool {
        guard let path else { return false }
        return path.hasPrefix("/System/") || path.hasPrefix("/usr/") && !path.hasPrefix("/usr/local/")
    }

    /// Open files and working folders through `libproc`, as `lsof` reads them. Memory-mapped files whose descriptor was closed are not
    /// seen; deleting one is harmless to the process that maps it, and a tool that maps caches is found by its name instead.
    @Sendable static func liveHoldsOpen(_ paths: [String]) -> Bool? {
        // The kernel reports real paths (`/private/var/folders/…`), so the paths are compared in that form.
        let roots = paths.compactMap { path -> String? in
            guard let real = realpath(path, nil) else { return nil }
            defer { free(real) }
            return String(cString: real)
        }
        guard !roots.isEmpty else { return false }
        func isUnder(_ path: String) -> Bool { roots.contains { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") } }
        guard let pids = userPIDs() else { return nil }
        for pid in pids {
            let program = executablePath(pid)
            var folders = proc_vnodepathinfo()
            if proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &folders, Int32(MemoryLayout<proc_vnodepathinfo>.size)) > 0 {
                let cwd = withUnsafePointer(to: folders.pvi_cdir.vip_path) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) } }
                if isUnder(cwd) { return true }
            }
            let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard size > 0 else {
                if errno == ESRCH || isAppleSystemProgram(program) { continue }
                return nil
            }
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.size + 16)
            let listed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * MemoryLayout<proc_fdinfo>.size))
            guard listed > 0 else {
                if errno == ESRCH || isAppleSystemProgram(program) { continue }
                return nil
            }
            for fd in fds.prefix(Int(listed) / MemoryLayout<proc_fdinfo>.size) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
                var info = vnode_fdinfowithpath()
                guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, Int32(MemoryLayout<vnode_fdinfowithpath>.size)) > 0 else {
                    // Closed, or the process ended, since the listing.
                    if errno == EBADF || errno == ESRCH || isAppleSystemProgram(program) { continue }
                    return nil
                }
                let path = withUnsafePointer(to: info.pvip.vip_path) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) } }
                if isUnder(path) { return true }
            }
        }
        return false
    }

    @Sendable static func liveAppPath(_ bundleIdentifier: String) -> String? {
        #if canImport(AppKit)
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)?.standardizedFileURL.path
        #else
        return nil
        #endif
    }
}
