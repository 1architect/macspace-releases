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

/// Synchronous adapter over the bounded process-group runner; no plaintext output spool files.
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
        let limit = timeout ?? defaultTimeout ?? 60
        let output = BoundedCommand.run(executable, arguments: arguments, environment: ProcessInfo.processInfo.environment, timeout: limit)
        if output.timedOut { throw CommandRunnerError.timedOut(executable: executable, arguments: arguments, seconds: limit) }
        guard !output.truncated else { throw CommandRunnerError.launchFailed("Command output exceeded its limit") }
        let result = CommandResult(stdout: output.stdout, stderr: output.stderr, exitCode: output.status)
        guard result.exitCode == 0 else {
            throw CommandRunnerError.nonZeroExit(executable: executable, arguments: arguments, code: result.exitCode, stderr: String(decoding: result.stderr, as: UTF8.self))
        }
        return result
    }
}
