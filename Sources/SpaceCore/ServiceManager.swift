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
    public let hidden: Bool
    /// Runs as a plain process on this Mac rather than in a container.
    public let native: Bool
    /// For native services: how it is installed and whether an install/update is running.
    public let install: NativeInstall?
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
    private var cachedGateway: String?
    /// Services that run as plain macOS processes (Ollama), and Ollama's downloads/loads in flight.
    let processes = NativeProcesses()
    let ollama = OllamaState()

    /// Host address as seen from containers; services are also published there so stacks can reach them.
    public func gateway() async -> String {
        if let cachedGateway { return cachedGateway }
        let g = await cli.gateway() ?? Recipe.defaultGateway
        cachedGateway = g
        return g
    }

    public init(cli: ContainerCLI, store: RecipeStore) {
        self.cli = cli
        self.store = store
    }

    public static func live() throws -> ServiceManager {
        try SpacePaths.ensure()
        return ServiceManager(cli: try ContainerCLI(), store: try RecipeStore())
    }

    public func reloadRecipes() throws { store = try RecipeStore() }

    public var recipes: [Recipe] {
        let overrides = SpaceState.load().images
        return store.all.map { Self.applying(overrides, to: $0) }
    }

    public func recipe(_ id: String) throws -> Recipe {
        guard let r = store[id] else { throw ServiceError.unknownService(id) }
        return Self.applying(SpaceState.load().images, to: r)
    }

    /// The image the recipe ships with (before user overrides).
    public func defaultImage(_ id: String) throws -> String {
        guard let r = store[id] else { throw ServiceError.unknownService(id) }
        return r.image
    }

    static func applying(_ overrides: [String: String], to r: Recipe) -> Recipe {
        guard let img = overrides[r.id], !img.isEmpty else { return r }
        var copy = r
        copy.image = img
        return copy
    }

    // MARK: Status

    public func status() async throws -> [ServiceStatus] {
        let containers = Dictionary(try await cli.list().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [ServiceStatus] = []
        for r in recipes {
            let c = containers[r.containerName]
            var state = c.map { ServiceStatus.State(rawValue: $0.state) ?? .unknown } ?? .notCreated
            var install: NativeInstall?
            if let native = r.native {
                if await NativeProcesses.probe(nativeProbeURL(r)) { state = .running }
                else { state = NativeProcesses.executable(for: native) == nil ? .notCreated : .stopped }
                install = await nativeInstall(r, native)
            }
            out.append(ServiceStatus(
                id: r.id, name: r.name, image: c?.image ?? r.image,
                state: state,
                address: c?.addresses.first.map { $0.split(separator: "/").first.map(String.init) ?? $0 },
                ports: Dictionary(uniqueKeysWithValues: r.ports.map { ($0.name, $0.host) }),
                connection: r.connectionInfo,
                adminURL: r.adminURL.map { r.expand($0) },
                icon: r.icon, color: r.color, hidden: r.hidden ?? false, native: r.native != nil, install: install
            ))
        }
        return out
    }

    // MARK: Native services (plain macOS processes)

    func nativeProbeURL(_ r: Recipe) -> URL {
        if let h = r.health?.exec.first, h.hasPrefix("http"), let url = URL(string: r.expand(h)) { return url }
        return URL(string: "http://127.0.0.1:\(r.ports.first?.host ?? 0)/")!
    }

    func nativeInstall(_ r: Recipe, _ n: Recipe.Native) async -> NativeInstall {
        let path = NativeProcesses.executable(for: n)
        let job = await processes.jobState(r.id)
        return NativeInstall(source: NativeInstall.classify(path), path: path, brewAvailable: NativeProcesses.locateBrew() != nil,
                             formula: n.brew, downloadURL: n.download, installing: job.running, error: job.error)
    }

    public func installStatus(_ id: String) async throws -> NativeInstall {
        let r = try recipe(id)
        guard let n = r.native else { throw ActionError.failed("\(r.name) runs in a container; there's nothing to install.") }
        return await nativeInstall(r, n)
    }

    /// Installs a native service with Homebrew, in the background (poll `installStatus` or the service list).
    public func installNative(_ id: String) async throws -> NativeInstall {
        let (r, n) = try installTarget(id)
        if try await checkInstallable(r, n) { return await nativeInstall(r, n) }
        guard await processes.beginJob(id) else { return await nativeInstall(r, n) }
        Task { await self.runBrew(r, n, verb: "install", restart: false) }
        return await nativeInstall(r, n)
    }

    /// Same, waiting until it finishes (for the CLI).
    public func installNativeAndWait(_ id: String) async throws {
        let (r, n) = try installTarget(id)
        if try await checkInstallable(r, n) { return }
        guard await processes.beginJob(id) else { throw ActionError.failed("\(r.name) is already being installed.") }
        await runBrew(r, n, verb: "install", restart: false)
        if let error = await processes.jobState(id).error { throw ActionError.failed(error) }
    }

    private func installTarget(_ id: String) throws -> (Recipe, Recipe.Native) {
        let r = try recipe(id)
        guard let n = r.native else { throw ActionError.failed("\(r.name) runs in a container; there's nothing to install.") }
        return (r, n)
    }

    /// True when it's already installed (nothing to do); throws when it can't be installed automatically.
    private func checkInstallable(_ r: Recipe, _ n: Recipe.Native) async throws -> Bool {
        if NativeProcesses.executable(for: n) != nil { return true }
        let how = n.download.map { " Install it from \($0) and Space will find it." } ?? ""
        guard n.brew != nil else { throw ActionError.failed("\(r.name) can't be installed by Space.\(how)") }
        guard NativeProcesses.locateBrew() != nil else {
            throw ActionError.failed("Homebrew isn't installed, so Space can't install \(r.name) for you.\(how) (Or install Homebrew from https://brew.sh.)")
        }
        return false
    }

    private func runBrew(_ r: Recipe, _ n: Recipe.Native, verb: String, restart: Bool) async {
        var error = await NativeProcesses.brew(verb, formula: n.brew ?? r.id, id: r.id)
        if error == nil, NativeProcesses.executable(for: n) == nil { error = "Homebrew finished but \(r.name) wasn't found afterwards." }
        await processes.finishJob(r.id, error: error)
        if error == nil, restart { try? await self.restart(r.id) }
    }

    func nativeExecutableName(_ n: Recipe.Native) -> String {
        URL(fileURLWithPath: n.executables.first ?? "").lastPathComponent
    }

    func nativePID(_ r: Recipe, _ n: Recipe.Native) async -> Int32? {
        await processes.pid(id: r.id, executableName: nativeExecutableName(n), port: r.ports.first?.host ?? 0)
    }

    func startNative(_ r: Recipe, _ n: Recipe.Native) async throws {
        // Already answering (started earlier, or by the service's own app): nothing to do.
        if await NativeProcesses.probe(nativeProbeURL(r)) { return }
        var env = (r.env ?? [:]).mapValues { r.expand($0) }
        if r.id == "ollama" { env.merge(try ollamaEnvironment()) { _, new in new } }
        try await processes.start(id: r.id, name: r.name, native: n, env: env)
        try await waitHealthy(r.id, timeout: .seconds(30))
        if r.id == "ollama" { await ollamaRepin() }
    }

    public func status(_ id: String) async throws -> ServiceStatus {
        _ = try recipe(id)
        return try await status().first { $0.id == id }!
    }

    // MARK: Lifecycle

    public func start(_ id: String) async throws {
        let r = try recipe(id)
        if let native = r.native { return try await startNative(r, native) }
        // Shared services first, healthy before we continue.
        for dep in r.dependsOn ?? [] {
            if try await status(dep).state != .running { try await start(dep) }
            try await waitHealthy(dep)
        }
        for step in r.prepare ?? [] {
            _ = try? await runAction(step.service, step.action, params: step.params ?? [:])  // "already exists" is fine
        }
        for part in r.parts ?? [] {
            if try await status(part).state != .running { try await start(part) }
            try await waitHealthy(part)
        }
        let existing = try await cli.list().first { $0.id == r.containerName }
        if let existing {
            if !existing.isRunning { try await cli.start(r.containerName) }
            return
        }
        for v in r.volumes ?? [] { try await cli.ensureVolume(r.volumeName(v)) }
        try await cli.run(Self.runArguments(for: r, gateway: await gateway()))
    }

    /// Waits until the service's health check passes (or it has none and is running).
    public func waitHealthy(_ id: String, timeout: Duration = .seconds(120)) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if (try? await isHealthy(id)) == true { return }
            try await Task.sleep(for: .seconds(1))
        }
        throw ServiceError.notHealthy(id)
    }

    public func stop(_ id: String) async throws {
        let r = try recipe(id)
        if let native = r.native {
            return try await processes.stop(id: r.id, name: r.name, executableName: nativeExecutableName(native),
                                            probeURL: nativeProbeURL(r), port: r.ports.first?.host ?? 0)
        }
        if try await cli.list().contains(where: { $0.id == r.containerName && $0.isRunning }) {
            try await cli.stop(r.containerName)
        }
        for part in r.parts ?? [] { try await stop(part) }
    }

    public func restart(_ id: String) async throws {
        try await stop(id)
        try await start(id)
    }

    /// Deletes the container (volumes are kept) and starts it again from the recipe.
    /// Needed after config changes, since container settings are fixed at creation.
    public func recreate(_ id: String) async throws {
        let r = try recipe(id)
        if r.native != nil { return try await restart(id) }
        if try await cli.list().contains(where: { $0.id == r.containerName }) {
            try await cli.delete(r.containerName)
        }
        try await start(id)
    }

    /// Pulls the latest image (and its stack parts'), running `beforeUpdate` actions (e.g. backups) first.
    public func pullLatest(_ id: String) async throws {
        let r = try recipe(id)
        if let n = r.native { return try await updateNative(r, n) }
        if try await status(id).state == .running {
            for action in r.beforeUpdate ?? [] {
                let res = try await runAction(id, action)
                guard res.ok else { throw ActionError.failed("Update cancelled — \(action) failed: \(res.output)") }
            }
        }
        try await cli.pull(r.image)
        for part in r.parts ?? [] {
            let pr = try recipe(part)
            try await cli.pull(pr.image)
            if try await cli.list().contains(where: { $0.id == pr.containerName }) { try await cli.delete(pr.containerName) }
        }
        try await recreate(id)
    }

    /// Updates a native service the way it was installed: Homebrew upgrades, apps update themselves.
    func updateNative(_ r: Recipe, _ n: Recipe.Native) async throws {
        let info = await nativeInstall(r, n)
        switch info.source {
        case .none: throw ActionError.failed("\(r.name) isn't installed yet — install it first.")
        case .app: throw ActionError.failed("\(r.name) was installed as an app, which keeps itself up to date: use its menu bar icon → Check for Updates.")
        case .other: throw ActionError.failed("\(r.name) (\(info.path ?? "")) wasn't installed with Homebrew, so Space can't update it.")
        case .brew:
            guard info.brewAvailable else { throw ActionError.failed("Homebrew wasn't found, so Space can't update \(r.name).") }
            guard await processes.beginJob(r.id) else { throw ActionError.failed("\(r.name) is already being updated.") }
            let wasRunning = await NativeProcesses.probe(nativeProbeURL(r))
            await runBrew(r, n, verb: "upgrade", restart: wasRunning)
            if let error = await processes.jobState(r.id).error { throw ActionError.failed(error) }
        }
    }

    /// Ports are published on 127.0.0.1 only. Containers reach shared services at `{gateway}:<port>`
    /// through spaced's gateway relay (SpaceNet.GatewayRelay), which stays valid when services restart.
    static func runArguments(for r: Recipe, gateway: String = Recipe.defaultGateway) -> [String] {
        var args = ["--name", r.containerName, "--label", "space.service=\(r.id)"]
        for p in r.ports { args += ["--publish", "127.0.0.1:\(p.host):\(p.container)"] }
        for v in r.volumes ?? [] { args += ["--volume", "\(r.volumeName(v)):\(v.path)"] }
        for (k, v) in (r.env ?? [:]).sorted(by: { $0.key < $1.key }) { args += ["--env", "\(k)=\(r.expand(v, gateway: gateway))"] }
        if let u = r.user { args += ["--user", u] }
        if let m = r.memory { args += ["--memory", m] }
        if let c = r.cpus { args += ["--cpus", String(c)] }
        args += r.args ?? []
        return args + [r.image]
    }

    // MARK: Health

    public func isHealthy(_ id: String) async throws -> Bool {
        let r = try recipe(id)
        if r.native != nil { return await NativeProcesses.probe(nativeProbeURL(r)) }
        guard let health = r.health else { return try await status(id).state == .running }
        if health.exec.first?.hasPrefix("http") == true, let url = URL(string: r.expand(health.exec[0])) {
            // HTTP health check, run from spaced (for images without a shell).
            let (_, resp) = try await URLSession.shared.data(from: url)
            return ((resp as? HTTPURLResponse)?.statusCode ?? 500) < 400
        }
        return try await cli.execIn(r.containerName, health.exec).status == 0
    }

    // MARK: Stats

    public func stats() async throws -> [ServiceStats] {
        let now = Date()
        let byName = Dictionary(uniqueKeysWithValues: recipes.map { ($0.containerName, $0.id) })
        var native: [ServiceStats] = []
        for r in recipes {
            guard let n = r.native, let pid = await nativePID(r, n), let u = await NativeProcesses.usage(pid: pid) else { continue }
            var memory = u.rss
            // Models live in GPU memory, which `ps` doesn't count: report what Ollama says is loaded.
            if r.id == "ollama", let client = try? ollamaClient(), let loaded = try? await client.models("/api/ps") {
                memory = max(memory, loaded.reduce(0) { $0 + ($1.size ?? 0) })
            }
            native.append(ServiceStats(id: r.id, cpuPercent: u.cpu, memoryBytes: memory, memoryLimitBytes: nil, networkRxBytes: nil,
                                       networkTxBytes: nil, blockReadBytes: nil, blockWriteBytes: nil, processes: 1, sampledAt: now))
        }
        return native + (try await cli.stats()).compactMap { s in
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
        if try recipe(id).native != nil { return NativeProcesses.tailLog(id, lines: tail ?? 200) }
        return try await cli.logs(try recipe(id).containerName, tail: tail)
    }

    public func followLogs(_ id: String, tail: Int = 100) throws -> AsyncThrowingStream<String, any Error> {
        if try recipe(id).native != nil { return NativeProcesses.followLog(id, tail: tail) }
        return cli.followLogs(try recipe(id).containerName, tail: tail)
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
        if let native = r.native {
            guard let pid = await nativePID(r, native) else { return ClientsInfo(count: 0, clients: []) }
            let n = await NativeProcesses.connections(pid: pid, port: r.ports.first?.host ?? 0)
            return ClientsInfo(count: n, clients: n == 0 ? [] : ["\(n) connection\(n == 1 ? "" : "s")"])
        }
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
        if a.http != nil {
            var req = URLRequest(url: URL(string: r.expand(try a.url(with: params)))!)
            req.httpMethod = a.http?.method ?? "GET"
            req.timeoutInterval = 30
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(decoding: data, as: UTF8.self)
            let ok = (200..<300).contains(code)
            return ActionResult(ok: ok, output: (ok ? a.extracted(body) : "HTTP \(code): \(body)").trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let command = try a.command(with: params)
        let result: CommandResult
        if let image = a.image {
            guard let address = try await status(id).address else { throw ServiceError.notRunning(id) }
            let gw = await gateway()
            let fill = { (v: String) in r.expand(v.replacingOccurrences(of: "{address}", with: address), gateway: gw) }
            result = try await cli.runOnce(image: image, env: (a.env ?? [:]).mapValues(fill), args: command.map(fill))
        } else {
            result = try await cli.execIn(r.containerName, command)
        }
        let output = result.status == 0 ? a.extracted(result.stdout) : result.stderr + result.stdout
        return ActionResult(ok: result.status == 0, output: output.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

public enum ServiceError: Error, CustomStringConvertible {
    case unknownService(String)
    case notRunning(String)
    case notHealthy(String)
    public var description: String {
        switch self {
        case .unknownService(let id): "Unknown service '\(id)'"
        case .notRunning(let id): "'\(id)' isn't running"
        case .notHealthy(let id): "'\(id)' didn't become healthy in time — check its logs"
        }
    }
}
