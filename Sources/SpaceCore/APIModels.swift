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
        /// Owning project, for hostnames that belong to a project endpoint.
        public let project: String?
        public var id: String { name }
        public init(name: String, host: String, port: Int, up: Bool, url: String, service: Bool, project: String? = nil) {
            self.name = name; self.host = host; self.port = port; self.up = up; self.url = url; self.service = service
            self.project = project
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

public struct EndpointRequest: Codable, Sendable {
    /// Short label, e.g. "api" or "portal".
    public var name: String
    /// The port the app listens on.
    public var port: Int
    /// Optional hostname without the domain; default `<name>.<project>`.
    public var hostname: String?
    public init(name: String, port: Int, hostname: String? = nil) { self.name = name; self.port = port; self.hostname = hostname }
}

public struct ResourceLinkRequest: Codable, Sendable {
    public var service: String
    /// Resource kind id (e.g. `databases`, `buckets`); omit for services without sub-items (Redis, Mailpit…).
    public var kind: String?
    public var name: String?
    /// Create it first if it doesn't exist (starts the service when needed).
    public var create: Bool?
    public init(service: String, kind: String? = nil, name: String? = nil, create: Bool? = nil) {
        self.service = service; self.kind = kind; self.name = name; self.create = create
    }
}

public struct ProjectRequest: Codable, Sendable {
    public var name: String
    public var endpoints: [EndpointRequest]?
    public var resources: [ResourceLinkRequest]?
    public init(name: String, endpoints: [EndpointRequest]? = nil, resources: [ResourceLinkRequest]? = nil) {
        self.name = name; self.endpoints = endpoints; self.resources = resources
    }
}

public struct EndpointView: Codable, Sendable, Hashable, Identifiable {
    public let name: String
    public let port: Int
    /// Full hostname, e.g. "api.proposal-generator.localhost".
    public let host: String
    public let url: String
    /// Something is listening on the port right now.
    public let up: Bool
    public var id: String { name }
    public init(name: String, port: Int, host: String, url: String, up: Bool) {
        self.name = name; self.port = port; self.host = host; self.url = url; self.up = up
    }
}

public struct ResourceLinkView: Codable, Sendable, Hashable {
    public let service: String
    public let kind: String?
    public let name: String?
    /// The linked item no longer exists (only checked on single-project reads, when its service is running).
    public let missing: Bool?
    public init(service: String, kind: String?, name: String?, missing: Bool? = nil) {
        self.service = service; self.kind = kind; self.name = name; self.missing = missing
    }
    public var label: String { name.map { "\(service)/\($0)" } ?? service }
}

public struct ProjectView: Codable, Sendable, Hashable, Identifiable {
    public let name: String
    public let endpoints: [EndpointView]
    public let resources: [ResourceLinkView]
    /// Ready-to-paste .env contents: endpoint URLs plus the linked resources' connection settings.
    public let env: String
    public var id: String { name }
    public init(name: String, endpoints: [EndpointView], resources: [ResourceLinkView], env: String) {
        self.name = name; self.endpoints = endpoints; self.resources = resources; self.env = env
    }
}
