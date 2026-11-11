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
        abstract: "Projects: ports + http://<name>.localhost + a database/bucket per service + .env",
        subcommands: [ProjectList.self, ProjectCreate.self, ProjectEnv.self, ProjectDelete.self],
        defaultSubcommand: ProjectList.self
    )
}

struct ProjectList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ls")
    func run() async throws {
        let list: [ProjectView] = try await Daemon().get("projects")
        if list.isEmpty { print("No projects. Create one: spaced project create acme --services postgres,rustfs,mailpit"); return }
        for p in list {
            let hosts = p.ports.sorted { $0.value < $1.value }.map { "http://\(p.hosts[$0.key] ?? "") → :\($0.value)" }
            print("\(p.name)  [\(p.services.joined(separator: ", "))]  \(hosts.joined(separator: "  "))")
        }
    }
}

struct ProjectCreate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create")
    @Argument var name: String
    @Option(help: "Comma-separated services, e.g. postgres,rustfs,mailpit,redis") var services = "postgres"
    @Option(help: "Comma-separated port names, first gets <name>.localhost") var ports = "web"
    func run() async throws {
        let p: ProjectView = try await Daemon().post("projects", body: ProjectRequest(
            name: name, services: services.split(separator: ",").map(String.init), ports: ports.split(separator: ",").map(String.init)))
        print(p.env)
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
    static let configuration = CommandConfiguration(commandName: "rm")
    @Argument var name: String
    @Flag(help: "Also delete its databases/users/buckets") var dropData = false
    func run() async throws {
        let _: OKReply = try await Daemon().call("DELETE", "projects/\(name)?dropData=\(dropData)")
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
