import Darwin
import Foundation
import SpaceCore
import Synchronization

/// Local hostnames: `http://<name>.localhost` → `localhost:<port>`.
///
/// Browsers and curl resolve `*.localhost` to loopback by themselves, so there is no DNS server,
/// resolver file, certificate or admin prompt. spaced listens on port 80 (127.0.0.1 and ::1), reads the
/// first request head, picks the site from its `Host` header, then relays raw bytes to the site's port —
/// which keeps WebSockets (dev-server HMR) and keep-alive working.
public actor Hostnames {
    public static let domain = "localhost"
    public static let defaultRouterPort = 80
    /// Longest request head we buffer before giving up.
    static let maxHeadBytes = 64 * 1024

    /// Port the router listens on (80 in production; tests use a free high port).
    public let routerPort: Int
    private let persistent: Bool
    private var state: SpaceState
    private var serviceSites: [SpaceState.Site] = []
    private var listeners: [Int32] = []
    private var routerError: String?
    private let table = RouteTable()

    public init() { self.init(routerPort: Self.defaultRouterPort) }

    /// `persistent: false` keeps sites in memory only (tests), instead of in state.json.
    public init(routerPort: Int, persistent: Bool = true) {
        self.routerPort = routerPort
        self.persistent = persistent
        state = persistent ? SpaceState.load() : SpaceState()
    }

    // MARK: Lifecycle

    /// Starts the Host-header router (no-op if it's already running).
    public func start() async throws {
        reload()
        guard listeners.isEmpty else { return }
        do {
            if routerPort < 1024 {
                // macOS only lets normal users bind low ports on the wildcard address; one dual-stack socket
                // covers 127.0.0.1 and ::1, and non-local peers are dropped below.
                listeners = [try Sockets.listenAnyDualStack(port: routerPort)]
            } else {
                listeners = [try Sockets.listen(port: routerPort)]
                // Browsers may try ::1 first for *.localhost; IPv6 is best effort.
                if let v6 = try? Sockets.listenIPv6Loopback(port: routerPort) { listeners.append(v6) }
            }
        } catch {
            routerError = "Can't listen on port \(routerPort): \(error)"
            throw error
        }
        routerError = nil
        let table = table
        for fd in listeners {
            Sockets.acceptLoop(fd, accept: Sockets.posixAccept) { conn in
                // Only this Mac may use the router; your dev apps never become reachable from the network.
                guard Sockets.peerIsLoopback(conn) else { close(conn); return }
                Self.serve(conn, table: table)
            }
        }
    }

    public func stop() {
        for fd in listeners {
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }
        listeners = []
    }

    // MARK: Sites

    static var namePattern: Regex<(Substring, Substring?, Substring?, Substring?)> { /^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$/ }

    /// "Acme.localhost" → "acme"; nil if invalid.
    static func normalize(_ raw: String) -> String? {
        var name = raw.lowercased().trimmingCharacters(in: .whitespaces)
        if name.hasSuffix(".\(domain)") { name.removeLast(domain.count + 1) }
        return name.wholeMatch(of: namePattern) != nil ? name : nil
    }

    public func addSite(name raw: String, port: Int) throws {
        guard let name = Self.normalize(raw) else { throw HostnameError.invalidName(raw) }
        guard (1...65535).contains(port), port != 80, port != 443, port != routerPort else { throw HostnameError.invalidPort(port) }
        reload()
        state.sites.removeAll { $0.name == name }
        state.sites.append(.init(name: name, port: port))
        if persistent { try state.save() }
        publish()
    }

    public func removeSite(_ raw: String) throws {
        let name = Self.normalize(raw) ?? raw
        reload()
        state.sites.removeAll { $0.name == name }
        if persistent { try state.save() }
        publish()
    }

    /// Sites for built-in services (e.g. mailpit.localhost → 8025). Routed but never persisted;
    /// a user site with the same name wins.
    public func setServiceSites(_ sites: [SpaceState.Site]) {
        serviceSites = sites.compactMap { s in
            guard let name = Self.normalize(s.name), (1...65535).contains(s.port) else { return nil }
            return .init(name: name, port: s.port)
        }
        publish()
    }

    private func reload() {
        if persistent { state = SpaceState.load() }
        publish()
    }

    /// User sites first, then service sites whose names aren't taken.
    private var allSites: [(site: SpaceState.Site, service: Bool)] {
        let user = state.sites.sorted { $0.name < $1.name }
        let taken = Set(user.map(\.name))
        let services = serviceSites.filter { !taken.contains($0.name) }.sorted { $0.name < $1.name }
        return user.map { ($0, false) } + services.map { ($0, true) }
    }

    private func publish() {
        table.set(allSites.map { RouteTable.Entry(name: $0.site.name, port: $0.site.port, service: $0.service) })
    }

    // MARK: Status

    public func status() async -> HostsStatus {
        reload()
        let used = Set(state.sites.map(\.port))
        let suggested = (3000..<4000).first { !used.contains($0) && Sockets.isFree(port: $0) } ?? 3000
        let sites = allSites.map { s, service in
            let host = Self.host(s.name)
            return HostsStatus.SiteView(name: s.name, host: host, port: s.port, up: Self.canConnect(s.port),
                                        url: Self.url(host: host, routerPort: routerPort), service: service)
        }
        return HostsStatus(domain: Self.domain, routerPort: routerPort, routerRunning: !listeners.isEmpty,
                           routerError: routerError, sites: sites, suggestedPort: suggested)
    }

    static func host(_ name: String) -> String { "\(name).\(domain)" }

    static func url(host: String, routerPort: Int) -> String {
        routerPort == 80 ? "http://\(host)" : "http://\(host):\(routerPort)"
    }

    static func canConnect(_ port: Int) -> Bool {
        guard let fd = try? Sockets.connect(port: port) else { return false }
        close(fd)
        return true
    }

    // MARK: Router

    /// Value of the `Host` header in a request head, if any.
    static func hostHeader(in head: [UInt8]) -> String? {
        let end = head.firstRange(of: Array("\r\n\r\n".utf8))?.lowerBound ?? head.count
        let text = String(decoding: head[..<end], as: UTF8.self)
        for line in text.split(separator: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            if line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == "host" {
                return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// "API.Acme.localhost:80" → "api.acme"; nil for other domains or bare "localhost".
    static func siteName(fromHost raw: String) -> String? {
        var host = raw.lowercased()
        if host.hasPrefix("[") { return nil }  // IPv6 literal
        if let colon = host.lastIndex(of: ":") { host = String(host[..<colon]) }
        if host.hasSuffix(".") { host.removeLast() }
        guard host.hasSuffix(".\(domain)") else { return nil }
        host.removeLast(domain.count + 1)
        return host.isEmpty ? nil : host
    }

    /// Handles one client connection (on its own thread).
    nonisolated static func serve(_ client: Int32, table: RouteTable) {
        Sockets.setReadTimeout(client, seconds: 30)
        let (head, complete) = Sockets.readUntil(client, Array("\r\n\r\n".utf8), limit: maxHeadBytes)
        guard complete else {
            if !head.isEmpty { respond(client, status: "431 Request Header Fields Too Large", title: "Request too large", body: "<p>The request head is too large.</p>") }
            close(client)
            return
        }
        let hostValue = hostHeader(in: head) ?? ""
        let entries = table.entries
        guard let name = siteName(fromHost: hostValue), let entry = entries.first(where: { $0.name == name }) else {
            respond(client, status: "404 Not Found", title: "No site here", body: notFoundBody(host: hostValue, entries: entries))
            close(client)
            return
        }
        guard let upstream = try? Sockets.connect(port: entry.port) else {
            respond(client, status: "502 Bad Gateway", title: "Nothing running",
                    body: "<p>Nothing is running on localhost:\(entry.port).</p><p>Start your app for <b>\(escape(host(entry.name)))</b> and reload.</p>")
            close(client)
            return
        }
        Sockets.setReadTimeout(client, seconds: nil)
        guard Sockets.writeAll(upstream, head) else { close(upstream); close(client); return }
        Sockets.relay(client, upstream)
    }

    static func notFoundBody(host: String, entries: [RouteTable.Entry]) -> String {
        var body = "<p>No site is configured for <b>\(escape(host.isEmpty ? "(no Host header)" : host))</b>.</p>"
        if entries.isEmpty {
            body += "<p>Add one from the Space app or with <code>spaced hosts add &lt;name&gt; &lt;port&gt;</code>.</p>"
        } else {
            body += "<p>Configured sites:</p><ul>"
            for e in entries {
                let h = escape(Self.host(e.name))
                body += "<li><a href=\"http://\(h)\">\(h)</a> → localhost:\(e.port)\(e.service ? " <small>(service)</small>" : "")</li>"
            }
            body += "</ul>"
        }
        return body
    }

    static func respond(_ fd: Int32, status: String, title: String, body: String) {
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><title>\(escape(title))</title>
        <style>body{font:15px -apple-system,system-ui,sans-serif;max-width:40em;margin:4em auto;padding:0 1em;color:#333}h1{font-size:1.4em}a{color:#0a66d8}</style>
        </head><body><h1>\(escape(title))</h1>\(body)<p><small>Space</small></p></body></html>
        """
        let bytes = Array(html.utf8)
        let headers = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
        Sockets.writeAll(fd, Array(headers.utf8) + bytes)
        shutdown(fd, SHUT_WR)
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// Current routes, shared with the router threads.
final class RouteTable: Sendable {
    struct Entry: Sendable, Hashable {
        let name: String
        let port: Int
        let service: Bool
    }

    private let storage = Mutex<[Entry]>([])
    var entries: [Entry] { storage.withLock { $0 } }
    func set(_ entries: [Entry]) { storage.withLock { $0 = entries } }
}

public enum HostnameError: Error, CustomStringConvertible {
    case invalidName(String)
    case invalidPort(Int)
    public var description: String {
        switch self {
        case .invalidName(let n): "'\(n)' isn't a valid hostname (lowercase letters, digits, hyphens; dots for subdomains)"
        case .invalidPort(let p): "Port \(p) can't be used for a site"
        }
    }
}
