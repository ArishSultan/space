import ArgumentParser
import Foundation
import SpaceCore

@main
struct Spaced: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "spaced",
        abstract: "Space: dev services on Apple container.",
        subcommands: [Recipes.self, Status.self, Start.self, Stop.self, Restart.self, Recreate.self,
                      Pull.self, Stats.self, Logs.self, Action.self, Serve.self, Net.self, Hosts.self, ProjectsCommand.self, SystemCommand.self, MCPCommand.self]
    )

    static func main() async {
        setvbuf(stdout, nil, _IOLBF, 0)  // show progress immediately even when piped
        await main(nil)
    }
}

struct JSONFlag: ParsableArguments {
    @Flag(name: .long, help: "Output JSON") var json = false
}

func printJSON(_ value: some Encodable) throws {
    let e = JSONEncoder()
    e.outputFormatting = [.prettyPrinted, .sortedKeys]
    e.dateEncodingStrategy = .iso8601
    print(String(decoding: try e.encode(value), as: UTF8.self))
}

struct Recipes: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List available services")
    @OptionGroup var out: JSONFlag
    func run() async throws {
        let recipes = try RecipeStore().all
        if out.json { return try printJSON(recipes) }
        for r in recipes {
            let actions = (r.actions ?? [:]).keys.sorted().joined(separator: ", ")
            print("\(r.id.padding(toLength: 10, withPad: " ", startingAt: 0)) \(r.image)\(actions.isEmpty ? "" : "  [\(actions)]")")
        }
    }
}

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show service status")
    @OptionGroup var out: JSONFlag
    func run() async throws {
        let status = try await ServiceManager.live().status()
        if out.json { return try printJSON(status) }
        for s in status {
            let ports = s.ports.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: " ")
            print("\(s.id.padding(toLength: 10, withPad: " ", startingAt: 0)) \(s.state.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0)) \(ports)")
        }
    }
}

struct ServiceArg: ParsableArguments {
    @Argument(help: "Service id") var service: String
}

struct Start: AsyncParsableCommand {
    @OptionGroup var arg: ServiceArg
    func run() async throws { try await ServiceManager.live().start(arg.service); print("started \(arg.service)") }
}

struct Stop: AsyncParsableCommand {
    @OptionGroup var arg: ServiceArg
    func run() async throws { try await ServiceManager.live().stop(arg.service); print("stopped \(arg.service)") }
}

struct Restart: AsyncParsableCommand {
    @OptionGroup var arg: ServiceArg
    func run() async throws { try await ServiceManager.live().restart(arg.service); print("restarted \(arg.service)") }
}

struct Recreate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Recreate the container from its recipe (data is kept)")
    @OptionGroup var arg: ServiceArg
    func run() async throws { try await ServiceManager.live().recreate(arg.service); print("recreated \(arg.service)") }
}

struct Pull: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Pull the latest image and recreate")
    @OptionGroup var arg: ServiceArg
    func run() async throws { try await ServiceManager.live().pullLatest(arg.service); print("updated \(arg.service)") }
}

struct Stats: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "CPU and memory per running service")
    @OptionGroup var out: JSONFlag
    func run() async throws {
        let m = try ServiceManager.live()
        _ = try await m.stats()  // first sample primes the CPU delta
        try await Task.sleep(for: .seconds(1))
        let stats = try await m.stats()
        if out.json { return try printJSON(stats) }
        for s in stats {
            let cpu = s.cpuPercent.map { String(format: "%5.1f%%", $0) } ?? "   - "
            let mem = s.memoryBytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .memory) } ?? "-"
            print("\(s.id.padding(toLength: 10, withPad: " ", startingAt: 0)) cpu \(cpu)  mem \(mem)")
        }
    }
}

struct Logs: AsyncParsableCommand {
    @OptionGroup var arg: ServiceArg
    @Option(name: .short, help: "Lines from the end") var n = 200
    @Flag(name: .shortAndLong, help: "Follow") var follow = false
    func run() async throws {
        let m = try ServiceManager.live()
        if follow {
            for try await line in try await m.followLogs(arg.service, tail: n) { print(line) }
        } else {
            print(try await m.logs(arg.service, tail: n), terminator: "")
        }
    }
}

struct Action: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run a recipe action, e.g. `spaced action postgres create_db name=acme`")
    @Argument var service: String
    @Argument var action: String
    @Argument(help: "key=value parameters") var params: [String] = []
    @OptionGroup var out: JSONFlag
    func run() async throws {
        var values: [String: String] = [:]
        for p in params {
            let parts = p.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { throw ValidationError("Expected key=value, got '\(p)'") }
            values[parts[0]] = parts[1]
        }
        let result = try await ServiceManager.live().runAction(service, action, params: values)
        if out.json { return try printJSON(result) }
        print(result.output)
        if !result.ok { throw ExitCode.failure }
    }
}
