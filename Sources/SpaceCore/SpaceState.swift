import Foundation

/// Persisted daemon state (plain JSON at ~/.config/space/state.json).
public struct SpaceState: Codable, Sendable, Equatable {
    /// A remote service tunnelled to localhost on this Mac.
    public struct Mount: Codable, Sendable, Hashable {
        public var peer: String
        public var service: String
        /// port name → (remote port, local port)
        public var ports: [String: PortPair]
        public init(peer: String, service: String, ports: [String: PortPair]) {
            self.peer = peer; self.service = service; self.ports = ports
        }
    }

    public struct PortPair: Codable, Sendable, Hashable {
        public var remote: Int
        public var local: Int
        public init(remote: Int, local: Int) { self.remote = remote; self.local = local }
    }

    /// A local hostname: `<name>.space.test` → localhost:`port`.
    public struct Site: Codable, Sendable, Hashable, Identifiable {
        /// Label(s) before the domain, e.g. "acme" or "api.acme".
        public var name: String
        public var port: Int
        public var id: String { name }
        public init(name: String, port: Int) { self.name = name; self.port = port }
    }

    public var tailnetEnabled = false
    public var sites: [Site] = []
    public var shared: Set<String> = []
    public var mounts: [Mount] = []

    public init() {}

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tailnetEnabled = try c.decodeIfPresent(Bool.self, forKey: .tailnetEnabled) ?? false
        shared = try c.decodeIfPresent(Set<String>.self, forKey: .shared) ?? []
        mounts = try c.decodeIfPresent([Mount].self, forKey: .mounts) ?? []
        sites = try c.decodeIfPresent([Site].self, forKey: .sites) ?? []
    }

    public static var url: URL { SpacePaths.root.appending(path: "state.json") }

    public static func load() -> SpaceState {
        guard let data = try? Data(contentsOf: url) else { return SpaceState() }
        return (try? JSONDecoder().decode(SpaceState.self, from: data)) ?? SpaceState()
    }

    public func save() throws {
        try SpacePaths.ensure()
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(self).write(to: Self.url, options: .atomic)
    }
}
