import Darwin
import Foundation
import SpaceCore

/// Makes every service reachable from containers at `<gateway>:<port>` (e.g. 192.168.64.1:5432) by relaying
/// to 127.0.0.1:<port>. Apple `container` can publish a port on only one host address, and services are
/// published on 127.0.0.1; the gateway address only exists on the container bridge, so this is not
/// reachable from the network. Retries until the bridge exists (it appears with the first container).
public actor GatewayRelay {
    let services: ServiceManager
    private var listeners: [Int: Int32] = [:]
    private var loop: Task<Void, Never>?

    public init(services: ServiceManager) { self.services = services }

    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sync()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    public func stop() {
        loop?.cancel(); loop = nil
        for fd in listeners.values { shutdown(fd, SHUT_RDWR); close(fd) }
        listeners = [:]
    }

    /// Opens listeners for any service port not covered yet (new recipes, bridge came up late).
    private func sync() async {
        let gateway = await services.gateway()
        for port in Set(await services.recipes.flatMap { $0.ports.map(\.host) }) where listeners[port] == nil {
            guard let fd = try? Sockets.listen(address: gateway, port: port) else { continue }
            listeners[port] = fd
            Sockets.acceptLoop(fd, accept: Sockets.posixAccept) { conn in
                guard let local = try? Sockets.connect(port: port) else { close(conn); return }
                Sockets.relay(conn, local)
            }
        }
    }

    public var ports: [Int] { listeners.keys.sorted() }
}
