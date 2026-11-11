import Foundation
import Hummingbird
import SpaceCore
import SpaceNet

struct PathReply: Codable, Sendable { let path: String }

struct Reply<T: Encodable & Sendable>: ResponseEncodable {
    let value: T
    init(_ value: T) { self.value = value }
    func encode(to encoder: any Encoder) throws { try value.encode(to: encoder) }
}

/// Turns Space errors into readable 400 responses.
struct ErrorMiddleware<Context: RequestContext>: RouterMiddleware {
    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        do { return try await next(request, context) }
        catch let e as HTTPError { throw e }
        catch { throw HTTPError(.badRequest, message: String(describing: error)) }
    }
}

public enum SpaceServer {
    public static let defaultPort = SpaceAPI.defaultPort

    /// Runs the daemon: local HTTP API on 127.0.0.1, plus tailnet sharing when logged in.
    public static func run(port: Int = defaultPort) async throws {
        signal(SIGPIPE, SIG_IGN)
        let services = try ServiceManager.live()
        let net = NetworkManager(services: services, apiPort: port)
        await net.bootstrap()
        let hosts = Hostnames()
        try? await hosts.start()

        let router = Router()
        router.add(middleware: ErrorMiddleware())
        routes(router, services: services, net: net, hosts: hosts)

        let app = Application(
            router: router,
            configuration: .init(address: .hostname("127.0.0.1", port: port), serverName: "spaced")
        )
        // Stop Caddy/dnsmasq when spaced shuts down (launchd sends SIGTERM).
        try await app.runService(gracefulShutdownSignals: [.sigterm, .sigint])
        await hosts.stop()
    }

    static func routes(_ r: Router<BasicRequestContext>, services: ServiceManager, net: NetworkManager, hosts: Hostnames) {
        let api = r.group("api")

        // Services
        api.get("services") { _, _ in
            let shared = await net.sharedServices
            let status = try await services.status()
            // Health checks exec into each running container; run them concurrently.
            let health = await withTaskGroup(of: (String, Bool?).self) { group in
                for s in status where s.state == .running {
                    group.addTask { (s.id, try? await services.isHealthy(s.id)) }
                }
                return await group.reduce(into: [String: Bool]()) { $0[$1.0] = $1.1 }
            }
            return Reply(status.map {
                ServiceView(id: $0.id, name: $0.name, image: $0.image, state: $0.state.rawValue, healthy: health[$0.id],
                            shared: shared.contains($0.id), ports: $0.ports, connection: $0.connection, adminURL: $0.adminURL,
                            icon: $0.icon, color: $0.color)
            })
        }
        api.get("services/:id/logo") { _, ctx -> Response in
            guard let data = try await services.logo(ctx.parameters.require("id")) else { throw HTTPError(.notFound) }
            return Response(
                status: .ok,
                headers: [.contentType: "image/png", .cacheControl: "max-age=86400"],
                body: .init(byteBuffer: ByteBuffer(bytes: data))
            )
        }
        api.get("services/:id/clients") { _, ctx in Reply(try await services.clients(ctx.parameters.require("id"))) }
        api.get("services/:id/recipe") { _, ctx in Reply(try await services.recipeView(ctx.parameters.require("id"))) }
        api.post("services/:id/override") { _, ctx in
            Reply(PathReply(path: try await services.makeOverride(ctx.parameters.require("id"))))
        }
        api.post("services/:id/apply") { _, ctx in try await services.applyConfig(ctx.parameters.require("id")); return Reply(OK()) }
        api.post("services/:id/recreate") { _, ctx in try await services.recreate(ctx.parameters.require("id")); return Reply(OK()) }
        api.get("services/:id/resources/:kind") { _, ctx in
            Reply(try await services.resources(ctx.parameters.require("id"), kind: ctx.parameters.require("kind")))
        }
        api.post("services/:id/start") { _, ctx in try await services.start(ctx.parameters.require("id")); return Reply(OK()) }
        api.post("services/:id/stop") { _, ctx in try await services.stop(ctx.parameters.require("id")); return Reply(OK()) }
        api.post("services/:id/restart") { _, ctx in try await services.restart(ctx.parameters.require("id")); return Reply(OK()) }
        api.post("services/:id/pull") { _, ctx in try await services.pullLatest(ctx.parameters.require("id")); return Reply(OK()) }
        api.get("services/:id/logs") { req, ctx in
            let tail = req.uri.queryParameters.get("tail", as: Int.self) ?? 200
            return try await services.logs(ctx.parameters.require("id"), tail: tail)
        }
        api.post("services/:id/actions/:action") { req, ctx in
            let body = (try? await req.decode(as: ActionRequest.self, context: ctx)) ?? ActionRequest()
            return Reply(try await services.runAction(ctx.parameters.require("id"), ctx.parameters.require("action"), params: body.params ?? [:]))
        }
        api.get("stats") { _, _ in Reply(try await services.stats()) }

        // Local hostnames (*.space.test)
        api.get("hosts") { _, _ in Reply(await hosts.status()) }
        api.post("hosts/sites") { req, ctx in
            let site = try await req.decode(as: SiteRequest.self, context: ctx)
            try await hosts.addSite(name: site.name, port: site.port)
            return Reply(await hosts.status())
        }
        api.delete("hosts/sites/:name") { _, ctx in
            try await hosts.removeSite(ctx.parameters.require("name"))
            return Reply(await hosts.status())
        }
        api.get("hosts/setup") { _, _ in
            try? await hosts.start()
            await hosts.waitForCertificateAuthority()
            return Reply(await hosts.setup())
        }
        api.post("hosts/restart") { _, _ in
            await hosts.stop()
            try await hosts.start()
            return Reply(await hosts.status())
        }

        // Tailnet
        api.get("net") { _, _ in Reply(await net.status()) }
        api.post("net/login") { _, _ in Reply(try await net.login()) }
        api.post("net/logout") { _, _ in try await net.logout(); return Reply(OK()) }
        api.get("net/peers") { _, _ in Reply(try await net.peers()) }
        api.get("net/peers/:peer/services") { _, ctx in Reply(try await net.remoteServices(peer: ctx.parameters.require("peer"))) }
        api.post("services/:id/share") { _, ctx in try await net.share(ctx.parameters.require("id")); return Reply(OK()) }
        api.post("services/:id/unshare") { _, ctx in try await net.unshare(ctx.parameters.require("id")); return Reply(OK()) }
        api.get("mounts") { _, _ in Reply(await net.mounts()) }
        api.post("mounts") { req, ctx in
            let m = try await req.decode(as: MountRequest.self, context: ctx)
            return Reply(try await net.mount(peer: m.peer, service: m.service))
        }
        api.delete("mounts/:peer/:service") { _, ctx in
            try await net.unmount(peer: ctx.parameters.require("peer"), service: ctx.parameters.require("service"))
            return Reply(OK())
        }
    }
}
