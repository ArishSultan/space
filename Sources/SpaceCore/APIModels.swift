import Foundation

// Types shared by the daemon API, the CLI and the menu-bar app.

/// Service status as served by the API.
public struct ServiceView: Codable, Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let image: String
    /// `not_created`, `stopped`, `running`, `stopping`, `unknown`
    public let state: String
    /// Health check result when running; nil when not running or no check defined.
    public let healthy: Bool?
    /// Reachable from other Space devices on the tailnet.
    public let shared: Bool
    public let ports: [String: Int]
    public let connection: [String: String]
    public let adminURL: String?
    public let icon: String?
    /// Hex colour, e.g. `#336791`.
    public let color: String?

    public init(id: String, name: String, image: String, state: String, healthy: Bool?, shared: Bool,
                ports: [String: Int], connection: [String: String], adminURL: String?, icon: String?, color: String?) {
        self.id = id; self.name = name; self.image = image; self.state = state; self.healthy = healthy
        self.shared = shared; self.ports = ports; self.connection = connection; self.adminURL = adminURL
        self.icon = icon; self.color = color
    }

    public var isRunning: Bool { state == "running" }
}

/// A peer's service as seen from this Mac (same shape as `ServiceView`).
public typealias RemoteService = ServiceView

public struct MountView: Codable, Sendable, Hashable {
    public let peer: String
    public let service: String
    public let active: Bool
    /// port name → local port on this Mac
    public let localPorts: [String: Int]
    /// Remote connection strings rewritten to this Mac's localhost ports.
    public let connection: [String: String]

    public init(peer: String, service: String, active: Bool, localPorts: [String: Int], connection: [String: String]) {
        self.peer = peer; self.service = service; self.active = active
        self.localPorts = localPorts; self.connection = connection
    }
}

/// Full service definition plus where it came from, for the Config tab.
public struct RecipeView: Codable, Sendable {
    public let recipe: Recipe
    /// Path of the user override file, if one exists.
    public let overridePath: String?
    public let yaml: String
    public init(recipe: Recipe, overridePath: String?, yaml: String) {
        self.recipe = recipe; self.overridePath = overridePath; self.yaml = yaml
    }
}

public struct ActionRequest: Codable, Sendable {
    public var params: [String: String]?
    public init(params: [String: String]? = nil) { self.params = params }
}

public struct MountRequest: Codable, Sendable {
    public var peer: String
    public var service: String
    public init(peer: String, service: String) { self.peer = peer; self.service = service }
}

public struct OK: Codable, Sendable {
    public var ok = true
    public init() {}
}

public struct ClientsInfo: Codable, Sendable, Hashable {
    public let count: Int
    /// Human-readable lines, e.g. "psql — shop@shop from 192.168.64.1" or "2 connections from this Mac".
    public let clients: [String]
    public init(count: Int, clients: [String]) { self.count = count; self.clients = clients }
}

/// Local hostname routing status (Caddy + dnsmasq under *.space.test).
public struct HostsStatus: Codable, Sendable {
    public struct SiteView: Codable, Sendable, Hashable, Identifiable {
        public let name: String
        public let host: String
        public let port: Int
        /// Something is listening on the target port right now.
        public let up: Bool
        public let urls: [String]
        public var id: String { name }
        public init(name: String, host: String, port: Int, up: Bool, urls: [String]) {
            self.name = name; self.host = host; self.port = port; self.up = up; self.urls = urls
        }
    }

    public let domain: String
    public let caddyInstalled: Bool
    public let dnsmasqInstalled: Bool
    /// /etc/resolver/<domain> points at our dnsmasq.
    public let resolverInstalled: Bool
    /// Caddy's local root certificate is trusted by the system.
    public let certificateTrusted: Bool
    public let proxyRunning: Bool
    public let dnsRunning: Bool
    public let sites: [SiteView]
    /// Next suggested port for a new site.
    public let suggestedPort: Int

    public var ready: Bool { caddyInstalled && dnsmasqInstalled && resolverInstalled && certificateTrusted }

    public init(domain: String, caddyInstalled: Bool, dnsmasqInstalled: Bool, resolverInstalled: Bool,
                certificateTrusted: Bool, proxyRunning: Bool, dnsRunning: Bool, sites: [SiteView], suggestedPort: Int) {
        self.domain = domain; self.caddyInstalled = caddyInstalled; self.dnsmasqInstalled = dnsmasqInstalled
        self.resolverInstalled = resolverInstalled; self.certificateTrusted = certificateTrusted
        self.proxyRunning = proxyRunning; self.dnsRunning = dnsRunning; self.sites = sites; self.suggestedPort = suggestedPort
    }
}

public struct SiteRequest: Codable, Sendable {
    public var name: String
    public var port: Int
    public init(name: String, port: Int) { self.name = name; self.port = port }
}

public struct SetupScript: Codable, Sendable {
    /// Shell script to run once with administrator privileges ("" when nothing to do).
    public let script: String
    /// Certificate to trust, if not trusted yet. Must be done as the user (macOS shows its own prompt);
    /// trust changes made from a root script are refused.
    public let certificate: String?
    public init(script: String, certificate: String?) { self.script = script; self.certificate = certificate }
}
