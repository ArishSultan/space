import Foundation
import Hummingbird
import HTTPTypes
import MCP
import SpaceCore
import SpaceMCP
import SpaceNet

extension SpaceServer {
    /// Projects, maintenance, image settings, live logs, MCP over HTTP and remote-Mac proxying.
    static func moreRoutes(_ r: Router<BasicRequestContext>, services: ServiceManager, net: NetworkManager,
                           projects: Projects, apiPort: Int) async throws {
        let api = r.group("api")
        let mcp = StatelessHTTPServerTransport()
        try await SpaceMCP.makeServer(api: SpaceAPI(port: apiPort)).start(transport: mcp)

        // Projects
        api.get("projects") { _, _ in Reply(try await projects.list()) }
        api.get("projects/:name") { _, ctx in Reply(try await projects.get(ctx.parameters.require("name"))) }
        api.get("projects/:name/env") { _, ctx in try await projects.get(ctx.parameters.require("name")).env }
        api.post("projects") { req, ctx in
            Reply(try await projects.create(try await req.decode(as: ProjectRequest.self, context: ctx)))
        }
        api.delete("projects/:name") { _, ctx in
            try await projects.delete(ctx.parameters.require("name"))
            return Reply(OK())
        }
        api.post("projects/:name/endpoints") { req, ctx in
            Reply(try await projects.addEndpoint(ctx.parameters.require("name"),
                                                 try await req.decode(as: EndpointRequest.self, context: ctx)))
        }
        api.delete("projects/:name/endpoints/:endpoint") { _, ctx in
            Reply(try await projects.removeEndpoint(ctx.parameters.require("name"), ctx.parameters.require("endpoint")))
        }
        api.post("projects/:name/resources") { req, ctx in
            Reply(try await projects.addResource(ctx.parameters.require("name"),
                                                 try await req.decode(as: ResourceLinkRequest.self, context: ctx)))
        }
        // Unlink: DELETE projects/<name>/resources?service=postgres&kind=databases&name=shop_db
        api.delete("projects/:name/resources") { req, ctx in
            let q = req.uri.queryParameters
            guard let service = q.get("service") else { throw HTTPError(.badRequest, message: "Missing 'service'") }
            return Reply(try await projects.removeResource(
                ctx.parameters.require("name"), ResourceLinkRequest(service: service, kind: q.get("kind"), name: q.get("name"))))
        }

        ollamaRoutes(r, services: services)

        // Maintenance
        api.get("system/disk") { _, _ in Reply(try await services.diskUsage()) }
        api.post("system/reclaim") { req, ctx in
            let body = (try? await req.decode(as: ReclaimRequest.self, context: ctx)) ?? ReclaimRequest(includeData: false)
            return Reply(try await services.reclaim(includeData: body.includeData))
        }
        api.post("system/update-all") { _, _ in Reply(try await services.updateAll()) }
        api.get("images") { _, _ in Reply(await services.imageSettings()) }
        api.post("images/:id") { req, ctx in
            let body = try await req.decode(as: ImageOverrideRequest.self, context: ctx)
            try await services.setImage(ctx.parameters.require("id"), body.image)
            return Reply(await services.imageSettings())
        }

        // Live logs (text/event-stream: one `data:` event per line).
        api.get("services/:id/logs/stream") { req, ctx -> Response in
            let id = try ctx.parameters.require("id")
            let tail = req.uri.queryParameters.get("tail", as: Int.self) ?? 200
            let lines = try await services.followLogs(id, tail: tail)
            return Response(
                status: .ok,
                headers: [.contentType: "text/event-stream", .cacheControl: "no-cache"],
                body: ResponseBody { writer in
                    do {
                        for try await line in lines {
                            try await writer.write(ByteBuffer(string: "data: \(line)\n\n"))
                        }
                    } catch {}
                    try await writer.finish(nil)
                }
            )
        }

        // MCP over HTTP (Streamable HTTP, stateless) — `claude mcp add --transport http space http://127.0.0.1:7777/mcp`
        r.post("mcp") { req, _ -> Response in
            var request = req
            let body = try await request.collectBody(upTo: 8 * 1024 * 1024)
            var headers: [String: String] = [:]
            for f in req.headers { headers[f.name.rawName] = f.value }
            let response = await mcp.handleRequest(MCP.HTTPRequest(
                method: req.method.rawValue, headers: headers, body: Data(buffer: body), path: req.uri.path))
            var out = HTTPTypes.HTTPFields()
            for (k, v) in response.headers { if let name = HTTPTypes.HTTPField.Name(k) { out[name] = v } }
            let status = Hummingbird.HTTPResponse.Status(code: response.statusCode)
            if case .stream(let stream, _) = response {
                return Response(status: status, headers: out, body: ResponseBody { writer in
                    for try await chunk in stream { try await writer.write(ByteBuffer(bytes: chunk)) }
                    try await writer.finish(nil)
                })
            }
            return Response(status: status, headers: out, body: .init(byteBuffer: ByteBuffer(bytes: response.bodyData ?? Data())))
        }
        r.get("mcp") { _, _ in Response(status: .methodNotAllowed) }

        // Remote control: forward /api/peers/<peer>/proxy/<path> to that Mac's Space API over the tailnet.
        for method in [Hummingbird.HTTPRequest.Method.get, .post, .delete] {
            api.on("peers/:peer/proxy/**", method: method) { req, ctx -> Response in
                var request = req
                let peer = try ctx.parameters.require("peer")
                let path = ctx.parameters.getCatchAll().joined(separator: "/")
                let body = method == .get ? nil : Data(buffer: try await request.collectBody(upTo: 8 * 1024 * 1024))
                let (code, type, data) = try await net.proxy(peer: peer, method: method.rawValue, path: path,
                                                             query: req.uri.query, body: body)
                return Response(status: .init(code: code), headers: [.contentType: type],
                                body: .init(byteBuffer: ByteBuffer(bytes: data)))
            }
        }
    }
}
