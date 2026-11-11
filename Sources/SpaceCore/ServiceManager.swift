import Foundation

public struct ServiceStatus: Codable, Sendable {
    public enum State: String, Codable, Sendable { case notCreated = "not_created", stopped, running, stopping, unknown }
    public let id: String
    public let name: String
    public let image: String
    public let state: State
    public let address: String?
    public let ports: [String: Int]
    public let connection: [String: String]
    public let adminURL: String?
    public let icon: String?
    public let color: String?
}

public struct ServiceStats: Codable, Sendable {
    public let id: String
    /// Percent of one CPU (100 = one full core). Nil until two samples exist.
    public let cpuPercent: Double?
    public let memoryBytes: UInt64?
    public let memoryLimitBytes: UInt64?
    public let networkRxBytes: UInt64?
    public let networkTxBytes: UInt64?
    public let blockReadBytes: UInt64?
    public let blockWriteBytes: UInt64?
    public let processes: UInt64?
    public let sampledAt: Date
}

/// Core operations shared by the CLI, HTTP API and MCP server.
public actor ServiceManager {
    public let cli: ContainerCLI
    public private(set) var store: RecipeStore
    private var lastCPU: [String: (usec: UInt64, at: Date)] = [:]

    public init(cli: ContainerCLI, store: RecipeStore) {
        self.cli = cli
        self.store = store
    }

    public static func live() throws -> ServiceManager {
        try SpacePaths.ensure()
        return ServiceManager(cli: try ContainerCLI(), store: try RecipeStore())
    }

    public func reloadRecipes() throws { store = try RecipeStore() }

    public var recipes: [Recipe] { store.all }

    public func recipe(_ id: String) throws -> Recipe {
        guard let r = store[id] else { throw ServiceError.unknownService(id) }
        return r
    }

    // MARK: Status

    public func status() async throws -> [ServiceStatus] {
        let containers = Dictionary(try await cli.list().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return store.all.map { r in
            let c = containers[r.containerName]
            return ServiceStatus(
                id: r.id, name: r.name, image: c?.image ?? r.image,
                state: c.map { ServiceStatus.State(rawValue: $0.state) ?? .unknown } ?? .notCreated,
                address: c?.addresses.first.map { $0.split(separator: "/").first.map(String.init) ?? $0 },
                ports: Dictionary(uniqueKeysWithValues: r.ports.map { ($0.name, $0.host) }),
                connection: r.connectionInfo,
                adminURL: r.adminURL.map(r.expand),
                icon: r.icon, color: r.color
            )
        }
    }

    public func status(_ id: String) async throws -> ServiceStatus {
        _ = try recipe(id)
        return try await status().first { $0.id == id }!
    }

    // MARK: Lifecycle

    public func start(_ id: String) async throws {
        let r = try recipe(id)
        for dep in r.dependsOn ?? [] where try await status(dep).state != .running {
            try await start(dep)
        }
        let existing = try await cli.list().first { $0.id == r.containerName }
        if let existing {
            if !existing.isRunning { try await cli.start(r.containerName) }
            return
        }
        for v in r.volumes ?? [] { try await cli.ensureVolume(r.volumeName(v)) }
        try await cli.run(Self.runArguments(for: r))
    }

    public func stop(_ id: String) async throws {
        let r = try recipe(id)
        if try await cli.list().contains(where: { $0.id == r.containerName && $0.isRunning }) {
            try await cli.stop(r.containerName)
        }
    }

    public func restart(_ id: String) async throws {
        try await stop(id)
        try await start(id)
    }

    /// Deletes the container (volumes are kept) and starts it again from the recipe.
    /// Needed after config changes, since container settings are fixed at creation.
    public func recreate(_ id: String) async throws {
        let r = try recipe(id)
        if try await cli.list().contains(where: { $0.id == r.containerName }) {
            try await cli.delete(r.containerName)
        }
        try await start(id)
    }

    public func pullLatest(_ id: String) async throws {
        let r = try recipe(id)
        try await cli.pull(r.image)
        try await recreate(id)
    }

    static func runArguments(for r: Recipe) -> [String] {
        var args = ["--name", r.containerName, "--label", "space.service=\(r.id)"]
        for p in r.ports { args += ["--publish", "127.0.0.1:\(p.host):\(p.container)"] }
        for v in r.volumes ?? [] { args += ["--volume", "\(r.volumeName(v)):\(v.path)"] }
        for (k, v) in (r.env ?? [:]).sorted(by: { $0.key < $1.key }) { args += ["--env", "\(k)=\(v)"] }
        if let u = r.user { args += ["--user", u] }
        if let m = r.memory { args += ["--memory", m] }
        if let c = r.cpus { args += ["--cpus", String(c)] }
        return args + [r.image]
    }

    // MARK: Health

    public func isHealthy(_ id: String) async throws -> Bool {
        let r = try recipe(id)
        guard let health = r.health else { return try await status(id).state == .running }
        return try await cli.execIn(r.containerName, health.exec).status == 0
    }

    // MARK: Stats

    public func stats() async throws -> [ServiceStats] {
        let now = Date()
        let byName = Dictionary(uniqueKeysWithValues: store.all.map { ($0.containerName, $0.id) })
        return try await cli.stats().compactMap { s in
            guard let id = byName[s.id] else { return nil }
            var cpu: Double?
            if let usec = s.cpuUsageUsec {
                if let prev = lastCPU[id], usec >= prev.usec, now > prev.at {
                    cpu = Double(usec - prev.usec) / (now.timeIntervalSince(prev.at) * 1_000_000) * 100
                }
                lastCPU[id] = (usec, now)
            }
            return ServiceStats(
                id: id, cpuPercent: cpu, memoryBytes: s.memoryUsageBytes, memoryLimitBytes: s.memoryLimitBytes,
                networkRxBytes: s.networkRxBytes, networkTxBytes: s.networkTxBytes,
                blockReadBytes: s.blockReadBytes, blockWriteBytes: s.blockWriteBytes,
                processes: s.numProcesses, sampledAt: now
            )
        }
    }

    // MARK: Logs

    public func logs(_ id: String, tail: Int? = 200) async throws -> String {
        try await cli.logs(try recipe(id).containerName, tail: tail)
    }

    public func followLogs(_ id: String, tail: Int = 100) throws -> AsyncThrowingStream<String, any Error> {
        cli.followLogs(try recipe(id).containerName, tail: tail)
    }

    // MARK: Recipes & resources

    public func logo(_ id: String) throws -> Data? {
        _ = try recipe(id)
        return try store.logoURL(id).map { try Data(contentsOf: $0) }
    }

    public func recipeView(_ id: String) throws -> RecipeView {
        let r = try recipe(id)
        return RecipeView(recipe: r, overridePath: store.overridePath(id), yaml: store.yaml(id))
    }

    /// Creates (or returns) the user override file for a recipe so it can be edited.
    public func makeOverride(_ id: String) throws -> String {
        _ = try recipe(id)
        return try store.makeOverride(id).path
    }

    /// Reloads recipes from disk and recreates the service so config changes take effect.
    public func applyConfig(_ id: String) async throws {
        try reloadRecipes()
        try await recreate(id)
    }

    public struct Resource: Codable, Sendable, Hashable {
        public let name: String
        public let connection: String?
    }

    public func resources(_ id: String, kind: String) async throws -> [Resource] {
        let r = try recipe(id)
        guard let res = r.resourceKind(kind) else { throw ActionError.unknownAction(kind) }
        let result = try await runAction(id, res.list)
        guard result.ok else { throw ActionError.failed(result.output) }
        // One name per line (tabs also separate, for CLIs that print lists on one line).
        return result.output.split(whereSeparator: { $0 == "\n" || $0 == "\t" })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.map { name in
            Resource(name: name, connection: res.connection.map { r.expand($0).replacingOccurrences(of: "{name}", with: name) })
        }
    }

    // MARK: Connected clients

    /// Who is connected right now. Uses the recipe's `clients` action when it has one (named clients),
    /// otherwise counts established TCP connections on the service's ports from inside the container.
    public func clients(_ id: String) async throws -> ClientsInfo {
        let r = try recipe(id)
        guard try await status(id).state == .running else { return ClientsInfo(count: 0, clients: []) }
        if let action = r.clients, let res = try? await runAction(id, action), res.ok {
            let lines = res.output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
            return ClientsInfo(count: lines.count, clients: lines)
        }
        let tcp = try await cli.execIn(r.containerName, ["cat", "/proc/net/tcp", "/proc/net/tcp6"])
        let peers = Self.establishedPeers(procNetTCP: tcp.stdout, ports: Set(r.ports.map(\.container)))
        let grouped = Dictionary(grouping: peers, by: { $0 }).mapValues(\.count)
        let labels = grouped.sorted { $0.key < $1.key }.map { ip, n in
            "\(n) connection\(n == 1 ? "" : "s") from \(ip.hasSuffix(".1") ? "this Mac" : ip)"
        }
        return ClientsInfo(count: peers.count, clients: labels)
    }

    /// Remote IPv4 addresses of ESTABLISHED connections to `ports`, excluding loopback (our own health checks).
    static func establishedPeers(procNetTCP: String, ports: Set<Int>) -> [String] {
        procNetTCP.split(separator: "\n").compactMap { line -> String? in
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count > 3, f[3] == "01" else { return nil }  // 01 = ESTABLISHED
            let local = f[1].split(separator: ":"), remote = f[2].split(separator: ":")
            guard local.count == 2, remote.count == 2, let lport = Int(local[1], radix: 16), ports.contains(lport) else { return nil }
            let hex = String(remote[0])
            // IPv4 is 8 hex chars, little-endian; IPv4-mapped IPv6 keeps it in the last 8.
            let v4 = hex.count == 8 ? hex : (hex.count == 32 && hex.dropFirst(16).hasPrefix("FFFF0000") ? String(hex.suffix(8)) : nil)
            guard let v4, let n = UInt32(v4, radix: 16) else { return nil }
            let ip = [n & 0xFF, (n >> 8) & 0xFF, (n >> 16) & 0xFF, n >> 24].map(String.init).joined(separator: ".")
            return ip.hasPrefix("127.") ? nil : ip
        }
    }

    // MARK: Actions

    public struct ActionResult: Codable, Sendable {
        public let ok: Bool
        public let output: String
    }

    public func runAction(_ id: String, _ action: String, params: [String: String] = [:]) async throws -> ActionResult {
        let r = try recipe(id)
        guard let a = r.actions?[action] else { throw ActionError.unknownAction(action) }
        if let name = params["name"],
           (r.resources ?? []).contains(where: { $0.drop == action && ($0.protected ?? []).contains(name) }) {
            throw ActionError.protected(name)
        }
        let command = try a.command(with: params)
        let result: CommandResult
        if let image = a.image {
            guard let address = try await status(id).address else { throw ServiceError.notRunning(id) }
            let fill = { (v: String) in v.replacingOccurrences(of: "{address}", with: address) }
            result = try await cli.runOnce(image: image, env: (a.env ?? [:]).mapValues(fill), args: command.map(fill))
        } else {
            result = try await cli.execIn(r.containerName, command)
        }
        let output = result.status == 0 ? result.stdout : result.stderr + result.stdout
        return ActionResult(ok: result.status == 0, output: output.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

public enum ServiceError: Error, CustomStringConvertible {
    case unknownService(String)
    case notRunning(String)
    public var description: String {
        switch self {
        case .unknownService(let id): "Unknown service '\(id)'"
        case .notRunning(let id): "'\(id)' isn't running"
        }
    }
}
