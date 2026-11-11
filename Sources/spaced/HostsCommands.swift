import ArgumentParser
import Foundation
import SpaceCore

struct Hosts: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Local hostnames: http://<name>.localhost → localhost:<port>",
        subcommands: [HostsStatus.self, HostsAdd.self, HostsRemove.self],
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
            print("\(site.up ? "●" : "○") \(site.url) → localhost:\(site.port)\(note)")
        }
        if !s.sites.contains(where: { !$0.service }) { print("No sites yet. Add one: spaced hosts add acme \(s.suggestedPort)") }
    }
}

struct HostsAdd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add", abstract: "Route http://<name>.localhost to a local port")
    @Argument(help: "e.g. acme or api.acme") var name: String
    @Argument var port: Int
    func run() async throws {
        let s: SpaceCore.HostsStatus = try await Daemon().post("hosts/sites", body: SiteRequest(name: name, port: port))
        let site = s.sites.first { !$0.service && ($0.name == name.lowercased() || $0.host == name.lowercased()) }
        print("\(site?.url ?? "http://\(name).localhost") → localhost:\(port)")
    }
}

struct HostsRemove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rm")
    @Argument var name: String
    func run() async throws {
        let _: SpaceCore.HostsStatus = try await Daemon().call("DELETE", "hosts/sites/\(name)")
        print("Removed \(name).localhost")
    }
}
