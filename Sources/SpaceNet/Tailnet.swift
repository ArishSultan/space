import Darwin
import Foundation
import SpaceCore
import TailscaleKit

/// Space's own tailnet identity, embedded via TailscaleKit (tsnet). No Tailscale app required.
/// Only this process is on the tailnet; other apps reach remote services through localhost tunnels.
public actor Tailnet {
    public let hostName: String
    public let stateDir: URL
    private var node: TailscaleNode?
    private var rawHandle: TailscaleHandle?
    private var localAPI: (base: URL, key: String)?
    private var whoisCache: [String: (login: String?, at: Date)] = [:]
    private var ownLogin: String?

    public init(hostName: String = Tailnet.defaultHostName, stateDir: URL = SpacePaths.root.appending(path: "tailscale")) {
        self.hostName = hostName
        self.stateDir = stateDir
    }

    public static var defaultHostName: String {
        let base = ProcessInfo.processInfo.hostName
            .replacingOccurrences(of: ".local", with: "")
            .lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return "space-" + String(base).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    public var isStarted: Bool { node != nil }

    /// Starts the embedded node. With saved credentials it reconnects silently;
    /// otherwise its status will carry an auth URL for browser login.
    public func start() async throws {
        guard node == nil else { return }
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let config = Configuration(hostName: hostName, path: stateDir.path, authKey: nil,
                                   controlURL: kDefaultControlURL, ephemeral: false)
        let node = try TailscaleNode(config: config, logger: TailnetLog())
        self.node = node
        rawHandle = await node.tailscale
    }

    public func stop() async {
        if let node { try? await node.close() }
        node = nil
        rawHandle = nil
        localAPI = nil
        ownLogin = nil
        whoisCache = [:]
    }

    /// Stops the node and forgets this device's credentials.
    public func logout() async {
        await stop()
        try? FileManager.default.removeItem(at: stateDir)
    }

    public func status() async -> TailnetStatus {
        guard let node, let data = try? await node.statusJSON() else { return .stopped }
        return TailnetStatus.parse(data) ?? .stopped
    }

    /// Starts if needed and waits briefly until we're either running or have an auth URL to show.
    public func login(timeout: Duration = .seconds(20)) async throws -> TailnetStatus {
        try await start()
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let s = await status()
            if s.loggedIn || s.authURL != nil { return s }
            try await Task.sleep(for: .milliseconds(300))
        }
        return await status()
    }

    public func waitUntilRunning(poll: Duration = .seconds(1)) async {
        while !Task.isCancelled {
            if await status().loggedIn { return }
            try? await Task.sleep(for: poll)
        }
    }

    private func handle() throws -> TailscaleHandle {
        guard let h = rawHandle else { throw TailnetError.notStarted }
        return h
    }

    // MARK: Identity

    /// Tailscale login (e.g. someone@gmail.com) owning the device at `ip`, via the node's LocalAPI whois.
    public func login(ofIP ip: String) async -> String? {
        if let c = whoisCache[ip], Date().timeIntervalSince(c.at) < 60 { return c.login }
        guard let api = try? await localAPIEndpoint() else { return nil }
        var comps = URLComponents(url: api.base.appending(path: "localapi/v0/whois"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "addr", value: ip)]
        var req = URLRequest(url: comps.url!)
        req.setValue("localapi", forHTTPHeaderField: "Sec-Tailscale")
        req.setValue("Basic " + Data(":\(api.key)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        struct WhoIs: Decodable { struct Profile: Decodable { let LoginName: String? }; let UserProfile: Profile? }
        let login = await (try? URLSession.shared.data(for: req)).flatMap { try? JSONDecoder().decode(WhoIs.self, from: $0.0) }?.UserProfile?.LoginName
        whoisCache[ip] = (login, Date())
        return login
    }

    /// The Tailscale login this Mac is signed in with.
    public func myLogin() async -> String? {
        if let ownLogin { return ownLogin }
        guard let ip = await status().me?.ips.first else { return nil }
        ownLogin = await login(ofIP: ip)
        return ownLogin
    }

    private func localAPIEndpoint() async throws -> (base: URL, key: String) {
        if let localAPI { return localAPI }
        guard let node else { throw TailnetError.notStarted }
        let cfg = try await node.loopback()
        guard let url = URL(string: "http://\(cfg.address)/") else { throw TailnetError.notStarted }
        localAPI = (url, cfg.localAPIKey)
        return localAPI!
    }

    /// Only devices signed in with the same Tailscale account as this Mac may connect.
    nonisolated func allowConnection(from ip: String?) -> Bool {
        guard let ip else { return false }
        return Blocking.run { [self] in
            guard let mine = await self.myLogin(), let theirs = await self.login(ofIP: ip) else { return false }
            return mine == theirs
        }
    }

    /// Listens on `port` on this node's tailnet address and forwards each connection to 127.0.0.1:`localPort`.
    /// Connections from devices of other Tailscale accounts (e.g. shared-in nodes) are refused.
    public func forward(tailnetPort port: Int, toLocal localPort: Int) throws -> Forwarder {
        let h = try handle()
        var listener: tailscale_listener = 0
        let rc = tailscale_listen(h, "tcp", ":\(port)", &listener)
        guard rc == 0 else { throw TailnetError.call("listen :\(port)", rc, Self.errmsg(h)) }
        let fd = listener
        Sockets.acceptLoop(fd, accept: { l in
            var conn: tailscale_conn = 0
            return tailscale_accept(l, &conn) == 0 ? conn : nil
        }, handler: { [self] conn in
            var buf = [CChar](repeating: 0, count: 64)
            let ip: String? = tailscale_getremoteaddr(fd, conn, &buf, buf.count) == 0
                ? String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self).split(separator: ":").dropLast().joined(separator: ":")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                : nil
            guard allowConnection(from: ip), let local = try? Sockets.connect(port: localPort) else { close(conn); return }
            Sockets.relay(conn, local)
        })
        return Forwarder(fd: fd, description: "tailnet:\(port) → localhost:\(localPort)")
    }

    /// Listens on 127.0.0.1:`localPort` and tunnels each connection to `host`:`port` over the tailnet.
    public func tunnel(local localPort: Int, to host: String, port: Int) throws -> Forwarder {
        let h = try handle()
        let fd = try Sockets.listen(port: localPort)
        Sockets.acceptLoop(fd, accept: Sockets.posixAccept) { conn in
            var remote: tailscale_conn = 0
            guard tailscale_dial(h, "tcp", "\(host):\(port)", &remote) == 0 else { close(conn); return }
            Sockets.relay(conn, remote)
        }
        return Forwarder(fd: fd, description: "localhost:\(localPort) → \(host):\(port)")
    }

    /// URLSession that routes through this node, for calling other Space daemons' APIs.
    public func urlSession() async throws -> URLSession {
        guard let node else { throw TailnetError.notStarted }
        let (config, _) = try await URLSessionConfiguration.tailscaleSession(node)
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config)
    }

    static func errmsg(_ h: TailscaleHandle) -> String {
        var buf = [CChar](repeating: 0, count: 512)
        _ = tailscale_errmsg(h, &buf, buf.count)
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// A running listener; `stop()` closes it and ends its accept loop.
public final class Forwarder: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32?
    public let description: String

    init(fd: Int32, description: String) {
        self.fd = fd
        self.description = description
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        if let fd { shutdown(fd, SHUT_RDWR); close(fd) }
        fd = nil
    }

    deinit { stop() }
}

public enum TailnetError: Error, CustomStringConvertible {
    case notStarted
    case notLoggedIn
    case call(String, Int32, String)

    public var description: String {
        switch self {
        case .notStarted: "Tailnet is off. Run `spaced net login`."
        case .notLoggedIn: "Not logged in to Tailscale yet. Run `spaced net login`."
        case .call(let what, let rc, let msg): "tailscale \(what) failed (\(rc)): \(msg)"
        }
    }
}

/// Sends tsnet's chatty logs to a file instead of stdout.
struct TailnetLog: LogSink {
    var logFileHandle: Int32? = {
        let path = SpacePaths.root.appending(path: "tailscale.log").path
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        return fd >= 0 ? fd : nil
    }()
    func log(_ message: String) {}
}

/// Bridges async work into the blocking connection threads.
enum Blocking {
    static func run<T: Sendable>(_ body: @escaping @Sendable () async -> T) -> T {
        let sem = DispatchSemaphore(value: 0)
        let box = Box<T>()
        Task { box.value = await body(); sem.signal() }
        sem.wait()
        return box.value!
    }

    final class Box<T>: @unchecked Sendable { var value: T? }
}
