import Darwin
import Foundation

/// Owned process group, bounded capture, and one execution/termination/drain deadline.
public enum BoundedCommand {
    public struct Result: Sendable {
        public let status: Int32
        public let stdout: Data
        public let stderr: Data
        public let timedOut: Bool
        public let truncated: Bool
        public var signal: Int32? = nil
    }
    public static func run(_ executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval,
                           maximumOutput: Int = 1_048_576) -> Result {
        guard timeout.isFinite, timeout > 0, maximumOutput > 0, maximumOutput <= 8 * 1024 * 1024,
              !([executable] + arguments + environment.map { $0.key + "=" + $0.value }).contains(where: { $0.utf8.contains(0) }) else {
            return Result(status: -1, stdout: Data(), stderr: Data(), timedOut: false, truncated: false)
        }
        let start = DispatchTime.now().uptimeNanoseconds
        let budget = UInt64(min(timeout, 86_400) * 1e9), deadline = start + budget
        let grace = min(budget / 3, 1_000_000_000), terminateAt = deadline - grace
        var out = [Int32](repeating: -1, count: 2), err = out
        guard pipe(&out) == 0 else { return Result(status: -1, stdout: Data(), stderr: Data(), timedOut: false, truncated: false) }
        guard pipe(&err) == 0 else { out.forEach { close($0) }; return Result(status: -1, stdout: Data(), stderr: Data(), timedOut: false, truncated: false) }
        defer { for fd in out + err where fd >= 0 { close(fd) } }
        for fd in out + err { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        var actions: posix_spawn_file_actions_t?, attrs: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return Result(status: -1, stdout: Data(), stderr: Data(), timedOut: false, truncated: false) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attrs) == 0 else { return Result(status: -1, stdout: Data(), stderr: Data(), timedOut: false, truncated: false) }
        defer { posix_spawnattr_destroy(&attrs) }
        let configured = [posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_SETPGROUP)), posix_spawnattr_setpgroup(&attrs, 0),
            posix_spawn_file_actions_adddup2(&actions, out[1], STDOUT_FILENO), posix_spawn_file_actions_adddup2(&actions, err[1], STDERR_FILENO),
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0),
            posix_spawn_file_actions_addchdir_np(&actions, "/")]
        guard configured.allSatisfy({ $0 == 0 }) else { return Result(status: -1, stdout: Data(), stderr: Data(), timedOut: false, truncated: false) }
        var argv = ([executable] + arguments).map { strdup($0) } + [nil]
        var envp = environment.sorted { $0.key < $1.key }.map { strdup($0.key + "=" + $0.value) } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: pid_t = 0
        let spawn = executable.withCString { posix_spawn(&pid, $0, &actions, &attrs, &argv, &envp) }
        close(out[1]); out[1] = -1; close(err[1]); err[1] = -1
        guard spawn == 0 else { return Result(status: -1, stdout: Data(), stderr: Data(), timedOut: false, truncated: false) }
        _ = fcntl(out[0], F_SETFL, O_NONBLOCK); _ = fcntl(err[0], F_SETFL, O_NONBLOCK)
        var streams = [Data(), Data()], ended = [false, false], truncated = false
        var exitStatus: Int32?, exitSignal: Int32?, timedOut = false, terminated = false, killed = false
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            // Never wait for EOF from an inherited descriptor beyond the shared deadline.
            if now >= deadline { timedOut = true; break }
            if exitStatus == nil {
                var information = siginfo_t()
                // Keep the exited parent unreaped until draining finishes: its PID reserves our process-group identity.
                if waitid(P_PID, id_t(pid), &information, WEXITED | WNOHANG | WNOWAIT) == 0, information.si_pid == pid {
                    exitStatus = information.si_code == CLD_EXITED ? information.si_status : -1
                    if information.si_code != CLD_EXITED { exitSignal = information.si_status }
                }
            }
            if now >= terminateAt, !terminated { _ = kill(-pid, SIGTERM); terminated = true; timedOut = true }
            if now >= terminateAt + grace / 2, !killed { _ = kill(-pid, SIGKILL); killed = true; timedOut = true }
            for (index, fd) in [out[0], err[0]].enumerated() where !ended[index] {
                for _ in 0..<32 {
                    let count = Darwin.read(fd, &buffer, buffer.count)
                    if count == 0 { ended[index] = true; break }
                    if count < 0 { if errno == EINTR { continue }; if errno != EAGAIN { ended[index] = true }; break }
                    let available = max(0, maximumOutput - streams[index].count)
                    streams[index].append(contentsOf: buffer.prefix(min(count, available)))
                    if count > available { truncated = true }
                }
            }
            if exitStatus != nil, ended.allSatisfy({ $0 }) { break }
            var descriptors = [pollfd(fd: ended[0] ? -1 : out[0], events: Int16(POLLIN | POLLHUP), revents: 0), pollfd(fd: ended[1] ? -1 : err[0], events: Int16(POLLIN | POLLHUP), revents: 0)]
            let remaining = max(1, min(10, Int((deadline - DispatchTime.now().uptimeNanoseconds.clamped(to: start...deadline)) / 1_000_000)))
            _ = poll(&descriptors, 2, Int32(remaining))
        }
        if timedOut || exitStatus == nil { _ = kill(-pid, SIGKILL) }
        var reapedStatus: Int32 = 0
        if waitpid(pid, &reapedStatus, WNOHANG) != pid {
            // Reap asynchronously if the kernel has not completed exit by the deadline.
            let child = pid
            DispatchQueue.global(qos: .utility).async { var status: Int32 = 0; while waitpid(child, &status, 0) < 0 && errno == EINTR {} }
        }
        return Result(status: timedOut ? -2 : (truncated ? -3 : exitStatus ?? -1), stdout: streams[0], stderr: streams[1], timedOut: timedOut, truncated: truncated, signal: exitSignal)
    }
}
private extension UInt64 { func clamped(to range: ClosedRange<UInt64>) -> UInt64 { Swift.min(Swift.max(self, range.lowerBound), range.upperBound) } }
