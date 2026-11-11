import ArgumentParser
import Foundation
import SpaceCore

struct Hosts: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Routed hostnames (project endpoints and built-in service UIs): http://<name>.localhost → localhost:<port>",
        subcommands: [HostsStatus.self],
        defaultSubcommand: HostsStatus.self
    )
}

struct HostsStatus: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status")
    @OptionGroup var out: JSONFlag
    func run() async throws {
        let s: SpaceCore.HostsStatus = try await Daemon().get("hosts")
        if out.json { return try printJSON(s) }
        if s.routerRunning {
            print("Router listening on port \(s.routerPort)")
        } else {
            print("Router not running\(s.routerError.map { ": \($0)" } ?? "")")
        }
        for site in s.sites {
            let note = site.service ? "  (service)" : site.up ? "" : "  (nothing listening yet)"
            let owner = site.project.map { "  [\($0)]" } ?? ""
            print("\(site.up ? "●" : "○") \(site.url) → localhost:\(site.port)\(owner)\(note)")
        }
        if !s.sites.contains(where: { !$0.service }) { print("No project hostnames yet. Add one: spaced project add-endpoint <project> api:\(s.suggestedPort)") }
    }
}
