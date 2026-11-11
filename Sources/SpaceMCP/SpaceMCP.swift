import Foundation
import MCP
import SpaceCore

/// MCP server exposing Space to agents. Every tool calls the spaced HTTP API, so agents get exactly
/// the behaviour (and safety checks) of the app and CLI.
public enum SpaceMCP {
    public static let instructions = """
    Space runs local development services (Postgres, MongoDB, Redis, Mailpit, S3 storage, Langfuse…) on this Mac \
    in Apple containers. Use these tools to start/stop services, create databases, users, buckets and whole \
    projects (an app's endpoints plus links to the databases/buckets it uses, with a ready .env), read logs and stats, inspect test emails, manage *.localhost hostnames and \
    share services with the user's other Macs. Credentials are local-dev defaults and safe to show.
    Stopping/restarting/updating a service with connected clients fails unless you pass force=true — check \
    list_clients first and tell the user who would be disconnected.
    """

    // MARK: Tool table

    struct ToolDef: Sendable {
        let name: String
        let description: String
        let params: [(String, String, String)]  // name, JSON type, description
        let required: [String]
        let run: @Sendable (SpaceAPI, [String: Value]) async throws -> String

        var tool: Tool {
            var props: [String: Value] = [:]
            for (n, t, d) in params {
                switch t {
                case "array": props[n] = .object(["type": "array", "items": .object(["type": "string"]), "description": .string(d)])
                case "objects": props[n] = .object(["type": "array", "items": .object(["type": "object"]), "description": .string(d)])
                default: props[n] = .object(["type": .string(t), "description": .string(d)])
                }
            }
            return Tool(name: name, description: description, inputSchema: .object([
                "type": "object", "properties": .object(props), "required": .array(required.map { .string($0) }),
            ]))
        }
    }

    static let service = ("service", "string", "Service id, e.g. postgres, mongodb, redis, mailpit, s3, langfuse")
    static let force = ("force", "boolean", "Proceed even if clients are connected (they will be disconnected)")

    static func str(_ a: [String: Value], _ k: String) throws -> String {
        guard let v = a[k]?.stringValue, !v.isEmpty else { throw MCPError.invalidParams("Missing '\(k)'") }
        return v
    }

    static func endpoints(_ v: Value?) throws -> [EndpointRequest]? {
        try v?.arrayValue?.map { item in
            guard let o = item.objectValue, let name = o["name"]?.stringValue, let port = o["port"]?.intValue else {
                throw MCPError.invalidParams("Each endpoint needs a name and a port")
            }
            return EndpointRequest(name: name, port: port, hostname: o["hostname"]?.stringValue)
        }
    }

    static func links(_ v: Value?) -> [ResourceLinkRequest]? {
        v?.arrayValue?.compactMap { item in
            guard let o = item.objectValue, let service = o["service"]?.stringValue else { return nil }
            return ResourceLinkRequest(service: service, kind: o["kind"]?.stringValue, name: o["name"]?.stringValue, create: o["create"]?.boolValue)
        }
    }

    static func summary(_ p: ProjectView) -> String {
        var out = "\(p.name)\n"
        for e in p.endpoints { out += "  endpoint \(e.name): \(e.url) → localhost:\(e.port)\(e.up ? "" : " (nothing listening yet)")\n" }
        for r in p.resources { out += "  uses \(r.label)\(r.kind.map { " (\($0))" } ?? "")\(r.missing == true ? " — MISSING" : "")\n" }
        return out + "\n.env:\n\(p.env)"
    }

    static func pretty(_ data: Data) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return String(decoding: data, as: UTF8.self) }
        return String(decoding: out, as: UTF8.self)
    }

    static func get(_ api: SpaceAPI, _ path: String, _ q: [String: String] = [:]) async throws -> String {
        pretty(try await api.raw("GET", path, query: q))
    }

    static func post(_ api: SpaceAPI, _ path: String, _ body: (any Encodable)? = nil) async throws -> String {
        pretty(try await api.raw("POST", path, body: body))
    }

    /// Refuses interrupting operations when clients are connected, unless forced.
    static func guardClients(_ api: SpaceAPI, _ id: String, _ a: [String: Value], verb: String) async throws {
        if a["force"]?.boolValue == true { return }
        let c: ClientsInfo = try await api.get("services/\(id)/clients")
        if c.count > 0 {
            throw MCPError.invalidRequest("\(id) has \(c.count) connected client(s): \(c.clients.joined(separator: "; ")). Ask the user, then call \(verb) again with force=true.")
        }
    }

    static func action(_ api: SpaceAPI, _ service: String, _ action: String, _ params: [String: String] = [:]) async throws -> String {
        let r: ServiceManager.ActionResult = try await api.post("services/\(service)/actions/\(action)", body: ActionRequest(params: params))
        guard r.ok else { throw MCPError.internalError(r.output) }
        return r.output.isEmpty ? "OK" : r.output
    }

    static let tools: [ToolDef] = [
        // Services
        .init(name: "list_services", description: "All services with state, health, ports and connection strings.", params: [], required: []) { api, _ in
            try await get(api, "services")
        },
        .init(name: "start_service", description: "Start a service (and its dependencies). Downloads the image on first use.", params: [service], required: ["service"]) { api, a in
            try await post(api, "services/\(try str(a, "service"))/start")
        },
        .init(name: "stop_service", description: "Stop a service. Data is kept.", params: [service, force], required: ["service"]) { api, a in
            let id = try str(a, "service"); try await guardClients(api, id, a, verb: "stop_service")
            return try await post(api, "services/\(id)/stop")
        },
        .init(name: "restart_service", description: "Restart a service.", params: [service, force], required: ["service"]) { api, a in
            let id = try str(a, "service"); try await guardClients(api, id, a, verb: "restart_service")
            return try await post(api, "services/\(id)/restart")
        },
        .init(name: "update_service", description: "Pull the latest image and recreate the service (data kept; backups taken first where defined).", params: [service, force], required: ["service"]) { api, a in
            let id = try str(a, "service"); try await guardClients(api, id, a, verb: "update_service")
            return try await post(api, "services/\(id)/pull")
        },
        .init(name: "get_connection_info", description: "Connection strings, ports and web UI for a service.", params: [service], required: ["service"]) { api, a in
            let id = try str(a, "service")
            let all: [ServiceView] = try await api.get("services")
            guard let s = all.first(where: { $0.id == id }) else { throw MCPError.invalidParams("Unknown service \(id)") }
            let out = ["state": s.state, "ports": s.ports.mapValues(String.init).description, "connection": s.connection.description, "web_ui": s.adminURL ?? "-"]
            return out.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        },
        .init(name: "list_clients", description: "Who is connected to a service right now.", params: [service], required: ["service"]) { api, a in
            try await get(api, "services/\(try str(a, "service"))/clients")
        },
        .init(name: "get_stats", description: "CPU %, memory, network and disk I/O for running services.", params: [], required: []) { api, _ in
            try await get(api, "stats")
        },
        .init(name: "get_logs", description: "Recent log lines of a service.", params: [service, ("tail", "integer", "Number of lines (default 200, max 5000)")], required: ["service"]) { api, a in
            let tail = min(max(a["tail"]?.intValue ?? 200, 1), 5000)
            return String(decoding: try await api.raw("GET", "services/\(try str(a, "service"))/logs", query: ["tail": String(tail)]), as: UTF8.self)
        },
        .init(name: "watch_logs", description: "Wait up to N seconds (max 60) and return only the log lines written meanwhile — useful right after triggering something.", params: [service, ("seconds", "integer", "How long to watch (default 10)")], required: ["service"]) { api, a in
            let id = try str(a, "service")
            let seconds = min(max(a["seconds"]?.intValue ?? 10, 1), 60)
            let before = String(decoding: try await api.raw("GET", "services/\(id)/logs", query: ["tail": "500"]), as: UTF8.self)
            try await Task.sleep(for: .seconds(seconds))
            let after = String(decoding: try await api.raw("GET", "services/\(id)/logs", query: ["tail": "2000"]), as: UTF8.self)
            let old = before.split(separator: "\n").last.map(String.init)
            var lines = after.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if let old, let idx = lines.lastIndex(of: old) { lines = Array(lines[(idx + 1)...]) }
            let fresh = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return fresh.isEmpty ? "(no new log lines in \(seconds)s)" : fresh
        },

        // Actions & resources
        .init(name: "list_actions", description: "Service-specific actions (with parameters) and resource kinds you can manage.", params: [service], required: ["service"]) { api, a in
            let rv: RecipeView = try await api.get("services/\(try str(a, "service"))/recipe")
            let actions = (rv.recipe.actions ?? [:]).sorted { $0.key < $1.key }.map { k, v in
                "- \(k)(\((v.params ?? []).joined(separator: ", "))): \(v.description)"
            }
            let kinds = (rv.recipe.resources ?? []).map { "- \($0.id): \($0.title) (create/delete \($0.kind)s by name)" }
            return "Actions:\n" + actions.joined(separator: "\n") + (kinds.isEmpty ? "" : "\n\nResource kinds:\n" + kinds.joined(separator: "\n"))
        },
        .init(name: "run_action", description: "Run a service action from list_actions.", params: [service, ("action", "string", "Action name"), ("params", "object", "Parameters, e.g. {\"name\": \"shop\"}")], required: ["service", "action"]) { api, a in
            var params: [String: String] = [:]
            for (k, v) in a["params"]?.objectValue ?? [:] { params[k] = v.stringValue ?? v.intValue.map(String.init) ?? "" }
            return try await action(api, try str(a, "service"), try str(a, "action"), params)
        },
        .init(name: "list_resources", description: "Databases, database + user pairs, users (Postgres, MongoDB) or buckets (S3 storage) with connection strings, and which projects use each.", params: [service, ("kind", "string", "Resource kind id, e.g. dbusers, databases, users, buckets")], required: ["service", "kind"]) { api, a in
            let id = try str(a, "service"), kind = try str(a, "kind")
            let out = try await get(api, "services/\(id)/resources/\(kind)")
            let projects: [ProjectView] = (try? await api.get("projects")) ?? []
            let used = projects.flatMap { p in p.resources.filter { $0.service == id && $0.kind == kind }.map { ($0.name ?? "", p.name) } }
            guard !used.isEmpty else { return out }
            return out + "\n\nUsed by projects:\n" + used.map { "- \($0.0): \($0.1)" }.joined(separator: "\n")
        },
        .init(name: "create_resource", description: "Create a database, a database + user pair (kind dbusers), a user or a bucket. Names: lowercase letters, digits, - or _. To also attach it to a project use add_project_resource with create=true.", params: [service, ("kind", "string", "dbusers, databases, users or buckets"), ("name", "string", "Name")], required: ["service", "kind", "name"]) { api, a in
            let id = try str(a, "service"), kind = try str(a, "kind"), name = try str(a, "name")
            let rv: RecipeView = try await api.get("services/\(id)/recipe")
            guard let create = rv.recipe.resourceKind(kind)?.create else { throw MCPError.invalidParams("\(id) can't create \(kind)") }
            let out = try await action(api, id, create, ["name": name])
            let conn = rv.recipe.resourceKind(kind)?.connection.map { rv.recipe.expand($0).replacingOccurrences(of: "{name}", with: name) }
            return out + (conn.map { "\nConnection: \($0)" } ?? "")
        },
        .init(name: "delete_resource", description: "Delete a database, database + user pair, user or bucket (its data is removed). Projects that link to it keep a dangling link (flagged MISSING).", params: [service, ("kind", "string", "Resource kind id"), ("name", "string", "Name")], required: ["service", "kind", "name"]) { api, a in
            let id = try str(a, "service"), kind = try str(a, "kind")
            let rv: RecipeView = try await api.get("services/\(id)/recipe")
            guard let drop = rv.recipe.resourceKind(kind)?.drop else { throw MCPError.invalidParams("\(id) can't delete \(kind)") }
            return try await action(api, id, drop, ["name": try str(a, "name")])
        },

        // Mail (Mailpit)
        .init(name: "mail_recent", description: "Latest 25 emails captured by Mailpit (id, date, from, to, subject).", params: [], required: []) { api, _ in
            try await action(api, "mailpit", "recent")
        },
        .init(name: "mail_search", description: "Search captured emails, e.g. 'to:user@x.com subject:welcome'.", params: [("query", "string", "Mailpit search query")], required: ["query"]) { api, a in
            try await action(api, "mailpit", "search", ["query": try str(a, "query")])
        },
        .init(name: "mail_get", description: "One email as JSON (headers, text and HTML body) — e.g. to grab a verification link.", params: [("id", "string", "Message id from mail_recent/mail_search")], required: ["id"]) { api, a in
            try await action(api, "mailpit", "message", ["id": try str(a, "id")])
        },
        .init(name: "mail_clear", description: "Delete all captured emails.", params: [], required: []) { api, _ in
            try await action(api, "mailpit", "clear")
        },

        // Projects (endpoints + links to resources) & hostnames
        .init(name: "list_projects", description: "Projects: each with its endpoints (hostname, port, whether something is listening) and the resources it links to (databases, buckets, Redis…).", params: [], required: []) { api, _ in
            try await get(api, "projects")
        },
        .init(name: "get_project", description: "One project with its endpoints, linked resources (flagging any that no longer exist) and .env.", params: [("name", "string", "Project name")], required: ["name"]) { api, a in
            try await get(api, "projects/\(try str(a, "name"))")
        },
        .init(name: "create_project", description: "Create a project: the app you're building. Give it endpoints (a port your app listens on + a http://<hostname>.localhost, default <endpoint>.<project>.localhost) and link the resources it uses. A link is only a reference: with create=true the resource is created first (its service is started if needed). Returns the project and its .env.", params: [("name", "string", "Project name (lowercase letters, digits, hyphens; 3+ chars)"), ("endpoints", "objects", "Optional. Each {name, port, hostname?}, e.g. {\"name\": \"api\", \"port\": 3100}"), ("resources", "objects", "Optional. Each {service, kind?, name?, create?}, e.g. {\"service\": \"postgres\", \"kind\": \"databases\", \"name\": \"shop\", \"create\": true}; Redis/Mailpit/Langfuse take just {service}")], required: ["name"]) { api, a in
            let req = ProjectRequest(name: try str(a, "name"), endpoints: try endpoints(a["endpoints"]), resources: links(a["resources"]))
            let p: ProjectView = try await api.post("projects", body: req)
            return summary(p)
        },
        .init(name: "add_endpoint", description: "Add an endpoint to a project: a port your app listens on, served at http://<hostname>.localhost.", params: [("project", "string", "Project name"), ("name", "string", "Endpoint label, e.g. api or portal"), ("port", "integer", "Port the app listens on"), ("hostname", "string", "Optional hostname without .localhost (default <name>.<project>)")], required: ["project", "name", "port"]) { api, a in
            guard let port = a["port"]?.intValue else { throw MCPError.invalidParams("Missing 'port'") }
            let p: ProjectView = try await api.post("projects/\(try str(a, "project"))/endpoints",
                body: EndpointRequest(name: try str(a, "name"), port: port, hostname: a["hostname"]?.stringValue))
            return summary(p)
        },
        .init(name: "remove_endpoint", description: "Remove an endpoint (and its hostname) from a project.", params: [("project", "string", "Project name"), ("name", "string", "Endpoint label")], required: ["project", "name"]) { api, a in
            pretty(try await api.raw("DELETE", "projects/\(try str(a, "project"))/endpoints/\(try str(a, "name"))"))
        },
        .init(name: "add_project_resource", description: "Link a resource to a project so its connection settings land in the project's .env. With create=true, creates the database/bucket first (starting the service if it's stopped). Postgres/MongoDB kinds: dbusers (database + user), databases, users; S3 storage: buckets. Redis, Mailpit and Langfuse: leave out kind and name.", params: [("project", "string", "Project name"), service, ("kind", "string", "Resource kind id from list_actions"), ("name", "string", "Resource name"), ("create", "boolean", "Create it if it doesn't exist")], required: ["project", "service"]) { api, a in
            let p: ProjectView = try await api.post("projects/\(try str(a, "project"))/resources",
                body: ResourceLinkRequest(service: try str(a, "service"), kind: a["kind"]?.stringValue, name: a["name"]?.stringValue, create: a["create"]?.boolValue))
            return summary(p)
        },
        .init(name: "remove_project_resource", description: "Unlink a resource from a project. The resource itself is not deleted (use delete_resource for that).", params: [("project", "string", "Project name"), service, ("kind", "string", "Resource kind id"), ("name", "string", "Resource name")], required: ["project", "service"]) { api, a in
            var q = ["service": try str(a, "service")]
            if let k = a["kind"]?.stringValue { q["kind"] = k }
            if let n = a["name"]?.stringValue { q["name"] = n }
            return pretty(try await api.raw("DELETE", "projects/\(try str(a, "project"))/resources", query: q))
        },
        .init(name: "get_project_env", description: "The .env for a project: endpoint URLs plus the linked resources' connection settings.", params: [("name", "string", "Project name")], required: ["name"]) { api, a in
            let p: ProjectView = try await api.get("projects/\(try str(a, "name"))")
            return p.env
        },
        .init(name: "delete_project", description: "Delete a project and its hostnames. Linked databases, buckets etc. are kept (delete them with delete_resource).", params: [("name", "string", "Project name")], required: ["name"]) { api, a in
            pretty(try await api.raw("DELETE", "projects/\(try str(a, "name"))"))
        },
        .init(name: "list_sites", description: "All routed hostnames (http://<name>.localhost → localhost:<port>): project endpoints and built-in service UIs.", params: [], required: []) { api, _ in
            try await get(api, "hosts")
        },

        // Other Macs (Tailscale)
        .init(name: "tailnet_status", description: "Whether this Mac is connected to the user's tailnet, and which services are shared/mounted.", params: [], required: []) { api, _ in
            try await get(api, "net")
        },
        .init(name: "list_peers", description: "Other Macs running Space on the tailnet.", params: [], required: []) { api, _ in
            try await get(api, "net/peers")
        },
        .init(name: "list_peer_services", description: "Services on another Mac.", params: [("peer", "string", "Peer name from list_peers")], required: ["peer"]) { api, a in
            try await get(api, "net/peers/\(try str(a, "peer"))/services")
        },
        .init(name: "share_service", description: "Let the user's other Macs use a service.", params: [service], required: ["service"]) { api, a in
            try await post(api, "services/\(try str(a, "service"))/share")
        },
        .init(name: "unshare_service", description: "Stop sharing a service.", params: [service], required: ["service"]) { api, a in
            try await post(api, "services/\(try str(a, "service"))/unshare")
        },
        .init(name: "use_remote_service", description: "Tunnel a service shared by another Mac to this Mac's localhost; returns connection strings.", params: [("peer", "string", "Peer name"), service], required: ["peer", "service"]) { api, a in
            try await post(api, "mounts", MountRequest(peer: try str(a, "peer"), service: try str(a, "service")))
        },
        .init(name: "stop_using_remote_service", description: "Remove a tunnel to another Mac's service.", params: [("peer", "string", "Peer name"), service], required: ["peer", "service"]) { api, a in
            pretty(try await api.raw("DELETE", "mounts/\(try str(a, "peer"))/\(try str(a, "service"))"))
        },

        // Maintenance
        .init(name: "disk_usage", description: "Disk used by images, containers and each service's data.", params: [], required: []) { api, _ in
            try await get(api, "system/disk")
        },
        .init(name: "reclaim_space", description: "Delete stopped Space containers and unused Space images (data kept). include_data also deletes data of stopped services — confirm with the user first.", params: [("include_data", "boolean", "Also delete data volumes of stopped services")], required: []) { api, a in
            try await post(api, "system/reclaim", ReclaimRequest(includeData: a["include_data"]?.boolValue == true))
        },
        .init(name: "update_all", description: "Pull the latest image for every installed service and recreate them.", params: [], required: []) { api, _ in
            try await post(api, "system/update-all")
        },
    ]

    // MARK: Server

    public static func makeServer(api: SpaceAPI = SpaceAPI()) async -> Server {
        let server = Server(
            name: "space", version: "0.1.0", title: "Space",
            instructions: instructions,
            capabilities: .init(resources: .init(subscribe: false, listChanged: false), tools: .init(listChanged: false))
        )
        let byName = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })

        await server.withMethodHandler(ListTools.self) { _ in .init(tools: tools.map(\.tool)) }
        await server.withMethodHandler(CallTool.self) { params in
            guard let def = byName[params.name] else {
                return .init(content: [.text(text: "Unknown tool \(params.name)", annotations: nil, _meta: nil)], isError: true)
            }
            do {
                let out = try await def.run(api, params.arguments ?? [:])
                return .init(content: [.text(text: out, annotations: nil, _meta: nil)], isError: false)
            } catch {
                let message: String = switch error {
                case SpaceAPI.Failure.daemonNotRunning: "Space isn't running on this Mac. Ask the user to open Space."
                case let e as MCPError: e.localizedDescription
                default: String(describing: error)
                }
                return .init(content: [.text(text: message, annotations: nil, _meta: nil)], isError: true)
            }
        }

        // Logs as resources: space://logs/<service>
        await server.withMethodHandler(ListResources.self) { _ in
            let services: [ServiceView] = (try? await api.get("services")) ?? []
            return .init(resources: services.filter { $0.state != "not_created" }.map {
                Resource(name: "\($0.name) logs", uri: "space://logs/\($0.id)", description: "Last 500 log lines", mimeType: "text/plain")
            })
        }
        await server.withMethodHandler(ReadResource.self) { params in
            guard params.uri.hasPrefix("space://logs/") else { throw MCPError.invalidParams("Unknown resource \(params.uri)") }
            let id = String(params.uri.dropFirst("space://logs/".count))
            let text = String(decoding: try await api.raw("GET", "services/\(id)/logs", query: ["tail": "500"]), as: UTF8.self)
            return .init(contents: [.text(text, uri: params.uri, mimeType: "text/plain")])
        }
        return server
    }

    /// Runs over stdin/stdout (for `claude mcp add space -- spaced mcp`).
    public static func runStdio() async throws {
        let server = await makeServer()
        try await server.start(transport: StdioTransport())
        while !Task.isCancelled { try await Task.sleep(for: .seconds(3600)) }
    }
}
