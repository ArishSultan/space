import ArgumentParser
import Foundation
import SpaceCore
import SpaceMCP

struct MCPCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Run the MCP server over stdio (claude mcp add space -- spaced mcp). Over HTTP it's at http://127.0.0.1:7777/mcp."
    )
    func run() async throws { try await SpaceMCP.runStdio() }
}

struct ProjectsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "project",
        abstract: "Projects: an app's endpoints (port + http://<hostname>.localhost) and links to the resources it uses",
        subcommands: [ProjectList.self, ProjectCreate.self, ProjectEndpoint.self, ProjectRmEndpoint.self,
                      ProjectLink.self, ProjectUnlink.self, ProjectEnv.self, ProjectDelete.self],
        defaultSubcommand: ProjectList.self
    )
}

func printProject(_ p: ProjectView) {
    print(p.name)
    for e in p.endpoints { print("  \(e.up ? "●" : "○") \(e.name): \(e.url) → localhost:\(e.port)") }
    for r in p.resources {
        print("  uses \(r.label)\(r.kind.map { " (\($0))" } ?? "")\(r.missing == true ? " — MISSING" : "")")
    }
}

struct ProjectList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ls")
    func run() async throws {
        let list: [ProjectView] = try await Daemon().get("projects")
        if list.isEmpty { print("No projects. Create one: spaced project create acme --endpoint api:3100 --endpoint portal:3101"); return }
        list.forEach(printProject)
    }
}

/// "api:3100" or "api:3100:api.acme" → endpoint request.
func parseEndpoint(_ s: String) throws -> EndpointRequest {
    let parts = s.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    guard parts.count >= 2, parts.count <= 3, let port = Int(parts[1]) else {
        throw ValidationError("Endpoint '\(s)' should look like api:3100 (or api:3100:hostname)")
    }
    return EndpointRequest(name: parts[0], port: port, hostname: parts.count == 3 ? parts[2] : nil)
}

/// "postgres/databases/shop" (create with a trailing "+") or just "redis".
func parseLink(_ s: String) throws -> ResourceLinkRequest {
    var text = s
    let create = text.hasSuffix("+")
    if create { text.removeLast() }
    let parts = text.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    switch parts.count {
    case 1: return ResourceLinkRequest(service: parts[0], create: create ? true : nil)
    case 3: return ResourceLinkRequest(service: parts[0], kind: parts[1], name: parts[2], create: create ? true : nil)
    default: throw ValidationError("Link '\(s)' should look like redis or postgres/databases/shop (add + to create it)")
    }
}

struct ProjectCreate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create")
    @Argument var name: String
    @Option(name: .customLong("endpoint"), help: "label:port[:hostname], e.g. api:3100. Repeatable.") var endpoints: [String] = []
    @Option(name: .customLong("uses"), help: "Resource to link, e.g. redis or postgres/databases/shop (end with + to create it). Repeatable.") var uses: [String] = []
    func run() async throws {
        let p: ProjectView = try await Daemon().post("projects", body: ProjectRequest(
            name: name, endpoints: try endpoints.map(parseEndpoint), resources: try uses.map(parseLink)))
        printProject(p)
    }
}

struct ProjectEndpoint: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add-endpoint", abstract: "Add an endpoint: a port served at http://<hostname>.localhost")
    @Argument var project: String
    @Argument(help: "label:port[:hostname], e.g. portal:3101") var endpoint: String
    func run() async throws {
        let p: ProjectView = try await Daemon().post("projects/\(project)/endpoints", body: try parseEndpoint(endpoint))
        printProject(p)
    }
}

struct ProjectRmEndpoint: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rm-endpoint")
    @Argument var project: String
    @Argument var endpoint: String
    func run() async throws {
        let p: ProjectView = try await Daemon().call("DELETE", "projects/\(project)/endpoints/\(endpoint)")
        printProject(p)
    }
}

struct ProjectLink: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "link", abstract: "Link a resource, e.g. redis or postgres/databases/shop (end with + to create it)")
    @Argument var project: String
    @Argument var resource: String
    func run() async throws {
        let p: ProjectView = try await Daemon().post("projects/\(project)/resources", body: try parseLink(resource))
        printProject(p)
    }
}

struct ProjectUnlink: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "unlink", abstract: "Unlink a resource (it is not deleted)")
    @Argument var project: String
    @Argument var resource: String
    func run() async throws {
        let l = try parseLink(resource)
        var query = ["service": l.service]
        if let k = l.kind { query["kind"] = k }
        if let n = l.name { query["name"] = n }
        _ = try await SpaceAPI().raw("DELETE", "projects/\(project)/resources", query: query)
        print("Unlinked \(resource) from \(project)")
    }
}

struct ProjectEnv: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "env", abstract: "Print the .env (pipe into a file)")
    @Argument var name: String
    func run() async throws {
        let p: ProjectView = try await Daemon().get("projects/\(name)")
        print(p.env, terminator: "")
    }
}

struct ProjectDelete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rm", abstract: "Delete a project and its hostnames (linked databases, buckets… are kept)")
    @Argument var name: String
    func run() async throws {
        do { _ = try await SpaceAPI().raw("DELETE", "projects/\(name)") }
        catch let SpaceAPI.Failure.server(msg) { throw ValidationError(msg) }
        print("Removed \(name)")
    }
}

struct SystemCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "system",
        abstract: "Disk usage, reclaim space, update everything",
        subcommands: [SystemDisk.self, SystemReclaim.self, SystemUpdateAll.self],
        defaultSubcommand: SystemDisk.self
    )
}

func bytes(_ b: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file) }

struct SystemDisk: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "disk")
    func run() async throws {
        let d: DiskUsage = try await Daemon().get("system/disk")
        print("Images      \(bytes(d.images.sizeInBytes))  (reclaimable \(bytes(d.images.reclaimable)))")
        print("Containers  \(bytes(d.containers.sizeInBytes))  (reclaimable \(bytes(d.containers.reclaimable)))")
        for v in d.spaceVolumes { print("Data \(v.service.padding(toLength: 12, withPad: " ", startingAt: 0)) \(bytes(v.bytes))") }
    }
}

struct SystemReclaim: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "reclaim",
        abstract: "Delete stopped Space containers and unused Space images (data kept)")
    @Flag(help: "Also delete data of services that aren't running") var includeData = false
    func run() async throws {
        let r: ReclaimResult = try await Daemon().post("system/reclaim", body: ReclaimRequest(includeData: includeData))
        r.removed.forEach { print("removed \($0)") }
        print("Freed \(bytes(r.freedBytes))")
    }
}

struct SystemUpdateAll: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update-all")
    func run() async throws {
        let r: UpdateResult = try await Daemon().post("system/update-all")
        print("Updated: \(r.updated.joined(separator: ", "))")
        for (k, v) in r.failed { print("Failed \(k): \(v)") }
    }
}
