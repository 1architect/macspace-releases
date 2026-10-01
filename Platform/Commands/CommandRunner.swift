import Foundation
import Darwin

public struct CommandResult: Sendable {
    public let stdout: Data
    public let stderr: Data
    public let exitCode: Int32

    public init(stdout: Data, stderr: Data, exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

public enum CommandRunnerError: Error, LocalizedError {
    case launchFailed(String)
    case timedOut(executable: String, arguments: [String], seconds: TimeInterval)
    case nonZeroExit(executable: String, arguments: [String], code: Int32, stderr: String)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let message):
            return "Failed to launch command: \(message)"
        case let .timedOut(executable, arguments, seconds):
            return "Command timed out after \(String(format: "%.1f", seconds))s: \(executable) \(arguments.joined(separator: " "))"
        case let .nonZeroExit(executable, arguments, code, stderr):
            return "Command failed (\(code)): \(executable) \(arguments.joined(separator: " "))\n\(stderr)"
        }
    }
}

public protocol CommandRunning: Sendable {
    func run(_ executable: String, _ arguments: [String]) throws -> CommandResult
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval?) throws -> CommandResult
}

public extension CommandRunning {
    /// Compatibility default for fixture/mock runners. Production ProcessCommandRunner
    /// overrides this and enforces the timeout.
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval?) throws -> CommandResult {
        try run(executable, arguments)
    }
}

/// Synchronous process runner that redirects output to temporary files instead of pipes.
/// This avoids the classic deadlock where a verbose child fills the pipe while the parent
/// waits for the child to exit. Optional per-command timeouts keep diagnostic probes bounded.
public struct ProcessCommandRunner: CommandRunning {
    public let defaultTimeout: TimeInterval?
    public let terminationGracePeriod: TimeInterval

    public init(defaultTimeout: TimeInterval? = 60, terminationGracePeriod: TimeInterval = 1.0) {
        self.defaultTimeout = defaultTimeout
        self.terminationGracePeriod = terminationGracePeriod
    }

    public func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        try run(executable, arguments, timeout: defaultTimeout)
    }

    public func run(_ executable: String, _ arguments: [String], timeout: TimeInterval?) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macspace-command-\(UUID().uuidString)", isDirectory: true)
        let stdoutURL = temporaryDirectory.appendingPathComponent("stdout")
        let stderrURL = temporaryDirectory.appendingPathComponent("stderr")

        do {
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        } catch {
            throw CommandRunnerError.launchFailed("Could not create command-output directory: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        _ = FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        _ = FileManager.default.createFile(atPath: stderrURL.path, contents: nil)

        let stdoutHandle: FileHandle
        let stderrHandle: FileHandle
        do {
            stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
            stderrHandle = try FileHandle(forWritingTo: stderrURL)
        } catch {
            throw CommandRunnerError.launchFailed("Could not open command-output files: \(error.localizedDescription)")
        }
        defer {
            try? stdoutHandle.close()
            try? stderrHandle.close()
        }

        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle

        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }

        do {
            try process.run()
        } catch {
            throw CommandRunnerError.launchFailed(error.localizedDescription)
        }

        let didTimeOut: Bool
        if let timeout, timeout > 0 {
            didTimeOut = terminated.wait(timeout: .now() + timeout) == .timedOut
        } else {
            terminated.wait()
            didTimeOut = false
        }

        if didTimeOut {
            process.terminate()
            if terminated.wait(timeout: .now() + terminationGracePeriod) == .timedOut {
                _ = kill(process.processIdentifier, SIGKILL)
                _ = terminated.wait(timeout: .now() + 1.0)
            }
            try? stdoutHandle.synchronize()
            try? stderrHandle.synchronize()
            throw CommandRunnerError.timedOut(
                executable: executable,
                arguments: arguments,
                seconds: timeout ?? 0
            )
        }

        try? stdoutHandle.synchronize()
        try? stderrHandle.synchronize()

        let stdoutData = (try? Data(contentsOf: stdoutURL)) ?? Data()
        let stderrData = (try? Data(contentsOf: stderrURL)) ?? Data()
        let result = CommandResult(
            stdout: stdoutData,
            stderr: stderrData,
            exitCode: process.terminationStatus
        )

        guard result.exitCode == 0 else {
            throw CommandRunnerError.nonZeroExit(
                executable: executable,
                arguments: arguments,
                code: result.exitCode,
                stderr: String(decoding: result.stderr, as: UTF8.self)
            )
        }
        return result
    }
}
