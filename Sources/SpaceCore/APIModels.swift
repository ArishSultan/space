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
    /// Part of a stack (e.g. Langfuse's ClickHouse); not shown in the main list.
    public let hidden: Bool?

    public init(id: String, name: String, image: String, state: String, healthy: Bool?, shared: Bool,
                ports: [String: Int], connection: [String: String], adminURL: String?, icon: String?, color: String?,
                hidden: Bool? = nil) {
        self.id = id; self.name = name; self.image = image; self.state = state; self.healthy = healthy
        self.shared = shared; self.ports = ports; self.connection = connection; self.adminURL = adminURL
        self.icon = icon; self.color = color; self.hidden = hidden
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

/// Local hostname routing status: `http://<name>.localhost` → localhost:<port> via spaced's built-in router.
public struct HostsStatus: Codable, Sendable {
    public struct SiteView: Codable, Sendable, Hashable, Identifiable {
        public let name: String
        public let host: String
        public let port: Int
        /// Something is listening on the target port right now.
        public let up: Bool
        /// e.g. "http://acme.localhost".
        public let url: String
        /// Added automatically for a built-in service (read-only, not saved in state.json).
        public let service: Bool
        public var id: String { name }
        public init(name: String, host: String, port: Int, up: Bool, url: String, service: Bool) {
            self.name = name; self.host = host; self.port = port; self.up = up; self.url = url; self.service = service
        }
    }

    public let domain: String
    /// Port the Host-header router listens on (80).
    public let routerPort: Int
    public let routerRunning: Bool
    /// Why the router couldn't start (e.g. port 80 already in use).
    public let routerError: String?
    public let sites: [SiteView]
    /// Next suggested port for a new site.
    public let suggestedPort: Int

    public var ready: Bool { routerRunning }

    public init(domain: String, routerPort: Int, routerRunning: Bool, routerError: String?, sites: [SiteView], suggestedPort: Int) {
        self.domain = domain; self.routerPort = routerPort; self.routerRunning = routerRunning
        self.routerError = routerError; self.sites = sites; self.suggestedPort = suggestedPort
    }
}

public struct SiteRequest: Codable, Sendable {
    public var name: String
    public var port: Int
    public init(name: String, port: Int) { self.name = name; self.port = port }
}

public struct ProjectRequest: Codable, Sendable {
    public var name: String
    /// Services the project uses, e.g. ["postgres", "rustfs", "mailpit"].
    public var services: [String]
    /// Named ports to reserve; the first gets `<name>.localhost`, others `<port>.<name>.localhost`. Default ["web"].
    public var ports: [String]?
    public init(name: String, services: [String], ports: [String]? = nil) {
        self.name = name; self.services = services; self.ports = ports
    }
}

public struct ProjectView: Codable, Sendable, Hashable, Identifiable {
    public let name: String
    public let services: [String]
    public let ports: [String: Int]
    /// Hostname per port name, e.g. ["web": "acme.localhost", "api": "api.acme.localhost"].
    public let hosts: [String: String]
    /// Ready-to-paste .env contents.
    public let env: String
    public var id: String { name }
    public init(name: String, services: [String], ports: [String: Int], hosts: [String: String], env: String) {
        self.name = name; self.services = services; self.ports = ports; self.hosts = hosts; self.env = env
    }
}
