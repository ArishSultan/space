import ArgumentParser
import Foundation
import SpaceCore

struct Hosts: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Local hostnames: <name>.space.test → localhost:<port> (HTTP + HTTPS)",
        subcommands: [HostsStatus.self, HostsSetup.self, HostsAdd.self, HostsRemove.self],
        defaultSubcommand: HostsStatus.self
    )
}

struct HostsStatus: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status")
    @OptionGroup var out: JSONFlag
    func run() async throws {
        let s: SpaceCore.HostsStatus = try await Daemon().get("hosts")
        if out.json { return try printJSON(s) }
        func mark(_ b: Bool) -> String { b ? "✓" : "✗" }
        print("Caddy \(mark(s.caddyInstalled))  dnsmasq \(mark(s.dnsmasqInstalled))  resolver \(mark(s.resolverInstalled))  certificate \(mark(s.certificateTrusted))  proxy \(mark(s.proxyRunning))  dns \(mark(s.dnsRunning))")
        if !s.ready { print("Run `spaced hosts setup` to finish the one-time setup.") }
        for site in s.sites {
            print("\(site.up ? "●" : "○") https://\(site.host) → localhost:\(site.port)\(site.up ? "" : "  (nothing listening yet)")")
        }
        if s.sites.isEmpty { print("No sites yet. Add one: spaced hosts add acme \(s.suggestedPort)") }
    }
}

struct HostsSetup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "setup", abstract: "One-time setup (asks for your password)")
    func run() async throws {
        let s: SetupScript = try await Daemon().get("hosts/setup")
        if s.script.isEmpty && s.certificate == nil { print("Already set up."); return }
        if !s.script.isEmpty {
            print("macOS will ask for your password to create /etc/resolver/space.test…")
            let r = try await AdminRunner.run(s.script)
            guard r.ok else { throw ValidationError("Resolver setup didn't finish: \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))") }
        }
        if let cert = s.certificate {
            print("macOS will ask you to allow trusting Space's local HTTPS certificate…")
            let r = try await CertificateTrust.trust(cert)
            guard r.ok else { throw ValidationError("Certificate trust didn't finish: \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))") }
        }
        print("Done.")
    }
}

struct HostsAdd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add", abstract: "Route <name>.space.test to a local port")
    @Argument(help: "e.g. acme or api.acme") var name: String
    @Argument var port: Int
    func run() async throws {
        let _: SpaceCore.HostsStatus = try await Daemon().post("hosts/sites", body: SiteRequest(name: name, port: port))
        print("https://\(name).space.test → localhost:\(port)")
    }
}

struct HostsRemove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rm")
    @Argument var name: String
    func run() async throws {
        let _: SpaceCore.HostsStatus = try await Daemon().call("DELETE", "hosts/sites/\(name)")
        print("Removed \(name).space.test")
    }
}
