import Darwin
import Foundation
import Testing
@testable import SpaceCore
@testable import SpaceNet

@Suite struct HostnameTests {
    @Test func siteNamesAreValidated() {
        for ok in ["acme", "api.acme", "my-app2"] { #expect(ok.wholeMatch(of: Hostnames.namePattern) != nil, "\(ok)") }
        for bad in ["-acme", "acme-", "Acme_1", "a..b", "", "acme/../x"] { #expect(bad.wholeMatch(of: Hostnames.namePattern) == nil, "\(bad)") }
        #expect(Hostnames.normalize("Acme.localhost") == "acme")
        #expect(Hostnames.normalize("api.acme") == "api.acme")
        #expect(Hostnames.normalize("bad_name") == nil)
    }

    @Test func hostHeaderIsParsed() {
        let head = Array("GET /x HTTP/1.1\r\nUser-Agent: t\r\nHOST:  Demo.LocalHost:8080 \r\nAccept: */*\r\n\r\nbody".utf8)
        #expect(Hostnames.hostHeader(in: head) == "Demo.LocalHost:8080")
        #expect(Hostnames.hostHeader(in: Array("GET / HTTP/1.0\r\n\r\n".utf8)) == nil)
    }

    @Test func siteNameFromHost() {
        #expect(Hostnames.siteName(fromHost: "demo.localhost") == "demo")
        #expect(Hostnames.siteName(fromHost: "API.Acme.localhost:80") == "api.acme")
        #expect(Hostnames.siteName(fromHost: "acme.localhost.") == "acme")
        #expect(Hostnames.siteName(fromHost: "localhost") == nil)
        #expect(Hostnames.siteName(fromHost: "localhost:80") == nil)
        #expect(Hostnames.siteName(fromHost: "example.com") == nil)
        #expect(Hostnames.siteName(fromHost: "[::1]:80") == nil)
        #expect(Hostnames.siteName(fromHost: "") == nil)
    }

    // MARK: Router integration

    private static func freePort() throws -> Int {
        let fd = try Sockets.listen(port: 0)
        defer { close(fd) }
        return try #require(Sockets.boundPort(fd))
    }

    /// A one-shot-per-connection HTTP responder that answers every request with `body`.
    private static func startResponder(body: String) throws -> (fd: Int32, port: Int) {
        let fd = try Sockets.listen(port: 0)
        let port = try #require(Sockets.boundPort(fd))
        Sockets.acceptLoop(fd, accept: Sockets.posixAccept) { conn in
            _ = Sockets.readUntil(conn, Array("\r\n\r\n".utf8), limit: 64 * 1024)
            Sockets.writeAll(conn, Array("HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8))
            shutdown(conn, SHUT_WR)
            close(conn)
        }
        return (fd, port)
    }

    /// Sends a raw request to the router and reads the whole response.
    private static func request(routerPort: Int, host: String) throws -> String {
        let fd = try Sockets.connect(port: routerPort)
        defer { close(fd) }
        Sockets.setReadTimeout(fd, seconds: 5)
        Sockets.writeAll(fd, Array("GET / HTTP/1.1\r\nHost: \(host)\r\n\r\n".utf8))
        // No terminator in a response, so this reads until the peer closes.
        let (bytes, _) = Sockets.readUntil(fd, Array("\u{0}\u{0}\u{0}\u{0}".utf8), limit: 1 << 20)
        return String(decoding: bytes, as: UTF8.self)
    }

    @Test func routerRelaysByHostHeader() async throws {
        let responder = try Self.startResponder(body: "hello from demo")
        defer { close(responder.fd) }
        let routerPort = try Self.freePort()
        let hosts = Hostnames(routerPort: routerPort, persistent: false)
        try await hosts.start()
        defer { Task { await hosts.stop() } }

        try await hosts.addSite(name: "demo", port: responder.port)
        let ok = try Self.request(routerPort: routerPort, host: "demo.localhost")
        #expect(ok.hasPrefix("HTTP/1.1 200 OK"))
        #expect(ok.hasSuffix("hello from demo"))

        let ok2 = try Self.request(routerPort: routerPort, host: "Demo.localhost:\(routerPort)")
        #expect(ok2.hasSuffix("hello from demo"))

        let missing = try Self.request(routerPort: routerPort, host: "nope.localhost")
        #expect(missing.hasPrefix("HTTP/1.1 404"))
        #expect(missing.contains("demo.localhost"))

        // Service sites are routed too, and shown as such in status.
        await hosts.setServiceSites([.init(name: "mailpit", port: responder.port)])
        let svc = try Self.request(routerPort: routerPort, host: "mailpit.localhost")
        #expect(svc.hasSuffix("hello from demo"))

        // Nothing listening on the target port → 502.
        let deadPort = try Self.freePort()
        try await hosts.addSite(name: "dead", port: deadPort)
        let dead = try Self.request(routerPort: routerPort, host: "dead.localhost")
        #expect(dead.hasPrefix("HTTP/1.1 502"))
        #expect(dead.contains("Nothing is running on localhost:\(deadPort)"))

        let status = await hosts.status()
        #expect(status.routerRunning)
        #expect(status.domain == "localhost")
        let byName = Dictionary(uniqueKeysWithValues: status.sites.map { ($0.name, $0) })
        #expect(byName["demo"]?.up == true)
        #expect(byName["demo"]?.service == false)
        #expect(byName["demo"]?.url == "http://demo.localhost:\(routerPort)")
        #expect(byName["mailpit"]?.service == true)
        #expect(byName["dead"]?.up == false)

        try await hosts.removeSite("demo")
        let gone = try Self.request(routerPort: routerPort, host: "demo.localhost")
        #expect(gone.hasPrefix("HTTP/1.1 404"))
    }
}
