import Foundation
import System

/// Thin wrapper over Apple's `container` CLI (1.x), using its JSON output.
public struct ContainerCLI: Sendable {
    public let executable: FilePath

    public init(executable: FilePath? = nil) throws {
        if let executable { self.executable = executable; return }
        guard let found = ProcessRunner.locate(["/usr/local/bin/container", "/opt/homebrew/bin/container"]) else {
            throw ContainerError.notInstalled
        }
        self.executable = found
    }

    // MARK: Models (only the fields we use; decoding is lenient)

    public struct ContainerInfo: Decodable, Sendable {
        public let id: String
        public let image: String
        public let state: String
        public let addresses: [String]
        public let labels: [String: String]

        private struct Raw: Decodable {
            struct Configuration: Decodable {
                struct Image: Decodable { let reference: String }
                let id: String
                let image: Image
                let labels: [String: String]?
            }
            struct Status: Decodable {
                struct Net: Decodable { let ipv4Address: String? }
                let state: String
                let networks: [Net]?
            }
            let configuration: Configuration
            let status: Status
        }

        public init(from decoder: any Decoder) throws {
            let raw = try Raw(from: decoder)
            id = raw.configuration.id
            image = raw.configuration.image.reference
            state = raw.status.state
            addresses = raw.status.networks?.compactMap(\.ipv4Address) ?? []
            labels = raw.configuration.labels ?? [:]
        }

        public var isRunning: Bool { state == "running" }
    }

    public struct Stats: Codable, Sendable {
        public let id: String
        public let memoryUsageBytes: UInt64?
        public let memoryLimitBytes: UInt64?
        public let cpuUsageUsec: UInt64?
        public let networkRxBytes: UInt64?
        public let networkTxBytes: UInt64?
        public let blockReadBytes: UInt64?
        public let blockWriteBytes: UInt64?
        public let numProcesses: UInt64?
    }

    // MARK: Commands

    public func list() async throws -> [ContainerInfo] {
        try JSONDecoder().decode([ContainerInfo].self, from: Data(try await checked(["ls", "--all", "--format", "json"]).utf8))
    }

    public func stats() async throws -> [Stats] {
        let out = try await checked(["stats", "--format", "json", "--no-stream"])
        return try JSONDecoder().decode([Stats].self, from: Data(out.utf8))
    }

    /// The default network's gateway: the host as seen from containers.
    public func gateway() async -> String? {
        struct Net: Decodable { struct Status: Decodable { let ipv4Gateway: String? }; let id: String; let status: Status? }
        guard let out = try? await checked(["network", "ls", "--format", "json"]),
              let nets = try? JSONDecoder().decode([Net].self, from: Data(out.utf8)) else { return nil }
        return nets.first { $0.id == "default" }?.status?.ipv4Gateway
    }

    public struct ImageInfo: Decodable, Sendable {
        public let name: String
        public let id: String
        private struct Raw: Decodable {
            struct Configuration: Decodable { let name: String }
            let configuration: Configuration
            let id: String
        }
        public init(from decoder: any Decoder) throws {
            let raw = try Raw(from: decoder)
            name = raw.configuration.name
            id = raw.id
        }
    }

    public func images() async throws -> [ImageInfo] {
        try JSONDecoder().decode([ImageInfo].self, from: Data(try await checked(["image", "ls", "--format", "json"]).utf8))
    }

    public func deleteImages(_ refs: [String]) async throws {
        guard !refs.isEmpty else { return }
        _ = try await checked(["image", "delete", "--force"] + refs)
    }

    public func pruneDanglingImages() async throws { _ = try await checked(["image", "prune"]) }

    public func deleteVolume(_ name: String) async throws { _ = try await checked(["volume", "delete", name]) }

    public func diskUsageJSON() async throws -> Data { Data(try await checked(["system", "df", "--format", "json"]).utf8) }

    public func run(_ args: [String]) async throws { _ = try await checked(["run", "--detach", "--progress", "none"] + args) }
    public func start(_ id: String) async throws { _ = try await checked(["start", id]) }
    public func stop(_ id: String) async throws { _ = try await checked(["stop", id]) }
    public func delete(_ id: String) async throws { _ = try await checked(["delete", "--force", id]) }
    public func pull(_ image: String) async throws { _ = try await checked(["image", "pull", "--progress", "none", image]) }

    /// Creates a named volume; "already exists" is not an error.
    public func ensureVolume(_ name: String) async throws {
        let r = try await exec(["volume", "create", name])
        if r.status != 0, !r.stderr.localizedCaseInsensitiveContains("exist") {
            throw ContainerError.commandFailed(["volume", "create", name], r.stderr)
        }
    }

    /// Runs a throwaway container to completion and returns its output.
    public func runOnce(image: String, env: [String: String], args: [String]) async throws -> CommandResult {
        var a = ["run", "--rm", "--progress", "none"]
        for (k, v) in env.sorted(by: { $0.key < $1.key }) { a += ["--env", "\(k)=\(v)"] }
        return try await exec(a + [image] + args)
    }

    public func execIn(_ id: String, _ command: [String]) async throws -> CommandResult {
        try await exec(["exec", id] + command)
    }

    public func logs(_ id: String, tail: Int?) async throws -> String {
        var args = ["logs"]
        if let tail { args += ["-n", String(tail)] }
        return try await checked(args + [id])
    }

    /// Streams log lines until the task is cancelled or the container stops.
    public func followLogs(_ id: String, tail: Int = 100) -> AsyncThrowingStream<String, any Error> {
        ProcessRunner.lines(executable, ["logs", "-f", "-n", String(tail), id])
    }

    // MARK: Plumbing

    public func exec(_ args: [String]) async throws -> CommandResult {
        try await ProcessRunner.run(executable, args)
    }

    @discardableResult
    func checked(_ args: [String]) async throws -> String {
        let r = try await exec(args)
        guard r.status == 0 else { throw ContainerError.commandFailed(args, r.stderr.isEmpty ? r.stdout : r.stderr) }
        return r.stdout
    }
}

public enum ContainerError: Error, CustomStringConvertible {
    case notInstalled
    case commandFailed([String], String)

    public var description: String {
        switch self {
        case .notInstalled:
            "Apple `container` CLI not found. Install it with `brew install container` and run `container system start`."
        case .commandFailed(let args, let msg):
            "`container \(args.joined(separator: " "))` failed: \(msg.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }
}
