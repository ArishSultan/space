import Foundation
import SpaceCore

/// Sharing local services on the tailnet and mounting remote ones on localhost.
public actor NetworkManager {
    public let services: ServiceManager
    public let tailnet: Tailnet
    public let apiPort: Int
    private var state: SpaceState
    private var shareForwarders: [String: [Forwarder]] = [:]
    private var mountForwarders: [String: [Forwarder]] = [:]  // key: peer/service
    private var apiForwarder: Forwarder?
    private var mountConnections: [String: [String: String]] = [:]
    private var activation: Task<Void, Never>?

    public init(services: ServiceManager, tailnet: Tailnet = Tailnet(), apiPort: Int) {
        self.services = services
        self.tailnet = tailnet
        self.apiPort = apiPort
        self.state = SpaceState.load()
    }

    // MARK: Lifecycle

    /// Called at daemon start: reconnect if previously logged in.
    public func bootstrap() async {
        guard state.tailnetEnabled else { return }
        try? await tailnet.start()
        activateWhenRunning()
    }

    public func login() async throws -> TailnetStatus {
        let s = try await tailnet.login()
        state.tailnetEnabled = true
        try state.save()
        activateWhenRunning()
        return s
    }

    public func logout() async throws {
        activation?.cancel()
        deactivate()
        await tailnet.logout()
        state.tailnetEnabled = false
        try state.save()
    }

    public func status() async -> TailnetStatus { await tailnet.status() }

    private func activateWhenRunning() {
        activation?.cancel()
        activation = Task {
            await tailnet.waitUntilRunning()
            guard !Task.isCancelled else { return }
            await activate()
        }
    }

    /// Opens the API on the tailnet, re-shares services and re-mounts remote ones.
    private func activate() async {
        if apiForwarder == nil {
            apiForwarder = try? await tailnet.forward(tailnetPort: apiPort, toLocal: apiPort)
        }
        for id in state.shared where shareForwarders[id] == nil { try? await openShare(id) }
        for m in state.mounts where mountForwarders[key(m.peer, m.service)] == nil { try? await openMount(m) }
    }

    private func deactivate() {
        apiForwarder?.stop(); apiForwarder = nil
        shareForwarders.values.flatMap { $0 }.forEach { $0.stop() }; shareForwarders = [:]
        mountForwarders.values.flatMap { $0 }.forEach { $0.stop() }; mountForwarders = [:]
    }

    // MARK: Sharing

    public var sharedServices: Set<String> { state.shared }

    public func share(_ id: String) async throws {
        _ = try await services.recipe(id)
        state.shared.insert(id)
        try state.save()
        if await tailnet.status().loggedIn, shareForwarders[id] == nil { try await openShare(id) }
    }

    public func unshare(_ id: String) throws {
        state.shared.remove(id)
        try state.save()
        shareForwarders.removeValue(forKey: id)?.forEach { $0.stop() }
    }

    private func openShare(_ id: String) async throws {
        let recipe = try await services.recipe(id)
        var fs: [Forwarder] = []
        for p in recipe.ports {
            fs.append(try await tailnet.forward(tailnetPort: p.host, toLocal: p.host))
        }
        shareForwarders[id] = fs
    }

    // MARK: Peers & remote services

    /// Other devices on the tailnet that run Space.
    public func peers() async throws -> [TailnetStatus.Device] {
        let s = await tailnet.status()
        guard s.loggedIn else { throw TailnetError.notLoggedIn }
        return s.peers.filter(\.isSpace)
    }

    public func remoteServices(peer: String) async throws -> [RemoteService] {
        guard await tailnet.status().loggedIn else { throw TailnetError.notLoggedIn }
        let session = try await tailnet.urlSession()
        let url = URL(string: "http://\(peer):\(apiPort)/api/services")!
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw RemoteError.badResponse(peer) }
        return try JSONDecoder().decode([RemoteService].self, from: data)
    }

    // MARK: Mounts

    public func mounts() -> [MountView] {
        state.mounts.map { m in
            MountView(peer: m.peer, service: m.service,
                      active: mountForwarders[key(m.peer, m.service)] != nil,
                      localPorts: m.ports.mapValues(\.local),
                      connection: mountConnections[key(m.peer, m.service)] ?? [:])
        }
    }

    /// Tunnels a peer's shared service to localhost, keeping the same port numbers when free.
    public func mount(peer: String, service: String) async throws -> MountView {
        let remote = try await remoteServices(peer: peer)
        guard let svc = remote.first(where: { $0.id == service }) else { throw RemoteError.unknownService(peer, service) }
        guard svc.shared else { throw RemoteError.notShared(peer, service) }

        let k = key(peer, service)
        mountForwarders.removeValue(forKey: k)?.forEach { $0.stop() }
        state.mounts.removeAll { $0.peer == peer && $0.service == service }

        let localRecipe = try? await services.recipe(service)
        let localStatus = try? await services.status(service)
        let localIsRunning = localStatus?.state == .running
        var pairs: [String: SpaceState.PortPair] = [:]
        var taken = Set(state.mounts.flatMap { $0.ports.values.map(\.local) })
        for (name, remotePort) in svc.ports.sorted(by: { $0.key < $1.key }) {
            // Keep the familiar port unless the local copy of the service (or anything else) holds it.
            let localServiceOwns = localIsRunning && localRecipe?.hostPort(name) == remotePort
            var local: Int? = (!localServiceOwns && !taken.contains(remotePort) && Sockets.isFree(port: remotePort)) ? remotePort : nil
            if local == nil { local = (15000..<17000).first { !taken.contains($0) && Sockets.isFree(port: $0) } }
            guard let local else { throw RemoteError.noFreePort }
            taken.insert(local)
            pairs[name] = .init(remote: remotePort, local: local)
        }
        let m = SpaceState.Mount(peer: peer, service: service, ports: pairs)
        mountConnections[k] = Self.rewrite(svc.connection, ports: pairs)
        try await openMount(m)
        state.mounts.append(m)
        try state.save()
        return mounts().first { $0.peer == peer && $0.service == service }!
    }

    public func unmount(peer: String, service: String) throws {
        mountForwarders.removeValue(forKey: key(peer, service))?.forEach { $0.stop() }
        mountConnections.removeValue(forKey: key(peer, service))
        state.mounts.removeAll { $0.peer == peer && $0.service == service }
        try state.save()
    }

    private func openMount(_ m: SpaceState.Mount) async throws {
        var fs: [Forwarder] = []
        do {
            for pair in m.ports.values {
                fs.append(try await tailnet.tunnel(local: pair.local, to: m.peer, port: pair.remote))
            }
        } catch {
            fs.forEach { $0.stop() }
            throw error
        }
        mountForwarders[key(m.peer, m.service)] = fs
        if mountConnections[key(m.peer, m.service)] == nil,
           let svc = try? await remoteServices(peer: m.peer).first(where: { $0.id == m.service }) {
            mountConnections[key(m.peer, m.service)] = Self.rewrite(svc.connection, ports: m.ports)
        }
    }

    /// Remote connection strings say `localhost:<remote port>`; point them at our local ports.
    static func rewrite(_ connection: [String: String], ports: [String: SpaceState.PortPair]) -> [String: String] {
        connection.mapValues { value in
            ports.values.reduce(value) { $0.replacingOccurrences(of: "localhost:\($1.remote)", with: "localhost:\($1.local)") }
        }
    }

    private func key(_ peer: String, _ service: String) -> String { "\(peer)/\(service)" }
}

public enum RemoteError: Error, CustomStringConvertible {
    case badResponse(String)
    case unknownService(String, String)
    case notShared(String, String)
    case noFreePort

    public var description: String {
        switch self {
        case .badResponse(let p): "\(p) did not answer like a Space daemon"
        case .unknownService(let p, let s): "\(p) has no service '\(s)'"
        case .notShared(let p, let s): "'\(s)' is not shared on \(p). On that Mac run `spaced net share \(s)`."
        case .noFreePort: "No free local port found"
        }
    }
}
