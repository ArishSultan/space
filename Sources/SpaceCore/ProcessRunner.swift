import Foundation
import Subprocess
import System

public struct CommandResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
    public var ok: Bool { status == 0 }
}

/// Shared helper for the external CLIs we drive (`container`, `tailscale`, …).
public enum ProcessRunner {
    public static func locate(_ candidates: [String]) -> FilePath? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { FilePath($0) }
    }

    public static func run(_ executable: FilePath, _ args: [String]) async throws -> CommandResult {
        let r = try await Subprocess.run(
            .path(executable),
            arguments: Arguments(args),
            output: .string(limit: 16 * 1024 * 1024),
            error: .string(limit: 1024 * 1024)
        )
        let code: Int32 = switch r.terminationStatus {
        case .exited(let c): Int32(c)
        default: -1
        }
        return CommandResult(status: code, stdout: r.standardOutput, stderr: r.standardError)
    }

    /// Streams combined stdout+stderr lines until the process exits or the consumer stops.
    public static func lines(_ executable: FilePath, _ args: [String]) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    _ = try await Subprocess.run(
                        .path(executable), arguments: Arguments(args),
                        input: .none, output: .sequence, error: .combinedWithOutput
                    ) { execution in
                        for try await line in execution.standardOutput.strings() {
                            continuation.yield(String(line))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
