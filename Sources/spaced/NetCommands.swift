import ArgumentParser
import Foundation
import SpaceCore
import SpaceNet
import SpaceServer

struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run the Space daemon (API on 127.0.0.1, tailnet sharing)")
    @Option(help: "API port") var port = SpaceServer.defaultPort
    func run() async throws {
        print("spaced listening on http://127.0.0.1:\(port)")
        try await SpaceServer.run(port: port)
    }
}

/// Talks to the local daemon; turns API errors into CLI validation errors.
struct Daemon {
    let api = SpaceAPI()
    func get<T: Decodable>(_ path: String, as: T.Type = T.self) async throws -> T { try await wrap { try await api.get(path) } }
    @discardableResult
    func post<T: Decodable>(_ path: String, body: (any Encodable)? = nil, as: T.Type = T.self) async throws -> T {
        try await wrap { try await api.post(path, body: body) }
    }
    func call<T: Decodable>(_ method: String, _ path: String) async throws -> T { try await wrap { try await api.call(method, path) } }
    private func wrap<T>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() }
        catch SpaceAPI.Failure.daemonNotRunning { throw ValidationError("Space daemon isn't running. Start it with `spaced serve`.") }
        catch let SpaceAPI.Failure.server(msg) { throw ValidationError(msg) }
    }
}

struct Net: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Use services across your Macs via an embedded Tailscale node (no Tailscale app needed)",
        subcommands: [NetStatus.self, NetLogin.self, NetLogout.self, NetPeers.self, NetShare.self, NetUnshare.self,
                      NetRemote.self, NetMount.self, NetUnmount.self, NetMounts.self],
        defaultSubcommand: NetStatus.self
    )
}

struct OKReply: Decodable { let ok: Bool }

struct NetStatus: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status")
    @OptionGroup var out: JSONFlag
    func run() async throws {
        let s: TailnetStatus = try await Daemon().get("net")
        if out.json { return try printJSON(s) }
        guard s.loggedIn, let me = s.me else { print("Tailnet: \(s.state). Run `spaced net login`."); return }
        print("This Mac is \(me.name) (\(me.ips.first ?? "")) on \(s.tailnet ?? "your tailnet")")
        let services: [RemoteService] = try await Daemon().get("services")
        let shared = services.filter(\.shared).map(\.id)
        print("Shared: \(shared.isEmpty ? "nothing" : shared.joined(separator: ", "))")
        let mounts: [MountView] = try await Daemon().get("mounts")
        for m in mounts {
            print("Mounted \(m.service) from \(m.peer) \(m.active ? "" : "(inactive) ")→ \(m.localPorts.map { "\($0.key) localhost:\($0.value)" }.joined(separator: ", "))")
        }
    }
}

struct NetLogin: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "login", abstract: "Join your tailnet (opens the browser once)")
    func run() async throws {
        let d = Daemon()
        var s: TailnetStatus = try await d.post("net/login")
        if s.loggedIn { print("Already on \(s.tailnet ?? "your tailnet") as \(s.me?.name ?? "?")."); return }
        guard let url = s.authURL else { throw ValidationError("Tailnet is \(s.state); no login URL yet. Try again in a moment.") }
        print("Opening \(url)\nWaiting for you to approve in the browser…")
        _ = try? await ProcessRunner.run("/usr/bin/open", [url])
        for _ in 0..<300 {
            try await Task.sleep(for: .seconds(1))
            s = try await d.get("net")
            if s.loggedIn { print("Joined \(s.tailnet ?? "your tailnet") as \(s.me?.name ?? "?")."); return }
        }
        throw ValidationError("Login not completed. Run `spaced net login` again.")
    }
}

struct NetLogout: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "logout", abstract: "Leave the tailnet and forget this device")
    func run() async throws { try await Daemon().post("net/logout", as: OKReply.self); print("Logged out.") }
}

struct NetPeers: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "peers", abstract: "Other Macs running Space")
    @OptionGroup var out: JSONFlag
    func run() async throws {
        let peers: [TailnetStatus.Device] = try await Daemon().get("net/peers")
        if out.json { return try printJSON(peers) }
        if peers.isEmpty { print("No other Space devices yet. Run `spaced net login` on your other Mac."); return }
        for p in peers { print("\(p.online ? "●" : "○") \(p.name)") }
    }
}

struct NetShare: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "share", abstract: "Let your other Macs use a service")
    @OptionGroup var arg: ServiceArg
    func run() async throws {
        try await Daemon().post("services/\(arg.service)/share", as: OKReply.self)
        print("\(arg.service) is shared on your tailnet.")
    }
}

struct NetUnshare: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "unshare")
    @OptionGroup var arg: ServiceArg
    func run() async throws {
        try await Daemon().post("services/\(arg.service)/unshare", as: OKReply.self)
        print("\(arg.service) is local-only.")
    }
}

struct NetRemote: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "remote", abstract: "List a peer's services")
    @Argument var peer: String
    @OptionGroup var out: JSONFlag
    func run() async throws {
        let list: [RemoteService] = try await Daemon().get("net/peers/\(peer)/services")
        if out.json { return try printJSON(list) }
        for s in list {
            print("\(s.id.padding(toLength: 10, withPad: " ", startingAt: 0)) \(s.state.padding(toLength: 12, withPad: " ", startingAt: 0)) \(s.shared ? "shared" : "-")")
        }
    }
}

struct NetMount: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "mount", abstract: "Use a peer's service on this Mac's localhost")
    @Argument var peer: String
    @Argument var service: String
    func run() async throws {
        let m: MountView = try await Daemon().post("mounts", body: MountRequest(peer: peer, service: service))
        print("\(service) from \(peer) is now on localhost:")
        for (k, v) in m.connection.sorted(by: { $0.key < $1.key }) { print("  \(k): \(v)") }
    }
}

struct NetUnmount: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "unmount")
    @Argument var peer: String
    @Argument var service: String
    func run() async throws {
        let _: OKReply = try await Daemon().call("DELETE", "mounts/\(peer)/\(service)")
        print("Unmounted \(service) from \(peer).")
    }
}

struct NetMounts: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "mounts")
    @OptionGroup var out: JSONFlag
    func run() async throws {
        let mounts: [MountView] = try await Daemon().get("mounts")
        if out.json { return try printJSON(mounts) }
        for m in mounts { print("\(m.peer)/\(m.service) \(m.active ? "active" : "inactive") \(m.localPorts)") }
    }
}
