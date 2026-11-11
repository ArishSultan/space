import Foundation
import SpaceCore

/// Projects tie things together: reserved ports with http://*.localhost hostnames, a resource in each chosen
/// service (database/user, bucket…) and a generated .env built from each service's `projectEnv` template.
public actor Projects {
    let services: ServiceManager
    let hosts: Hostnames

    public init(services: ServiceManager, hosts: Hostnames) {
        self.services = services
        self.hosts = hosts
    }

    static var namePattern: Regex<Substring> { /^[a-z0-9][a-z0-9-]{1,40}[a-z0-9]$/ }
    static var portNamePattern: Regex<Substring> { /^[a-z][a-z0-9-]{0,20}$/ }

    public func list() async throws -> [ProjectView] {
        let state = SpaceState.load()
        var out: [ProjectView] = []
        for p in state.projects.sorted(by: { $0.name < $1.name }) { out.append(try await view(p)) }
        return out
    }

    public func get(_ name: String) async throws -> ProjectView {
        guard let p = SpaceState.load().projects.first(where: { $0.name == name }) else { throw ProjectError.notFound(name) }
        return try await view(p)
    }

    public func create(_ req: ProjectRequest) async throws -> ProjectView {
        let name = req.name.lowercased()
        guard name.wholeMatch(of: Self.namePattern) != nil else { throw ProjectError.invalidName(req.name) }
        var state = SpaceState.load()
        guard !state.projects.contains(where: { $0.name == name }) else { throw ProjectError.exists(name) }
        let portNames = (req.ports?.isEmpty == false ? req.ports! : ["web"]).map { $0.lowercased() }
        for p in portNames where p.wholeMatch(of: Self.portNamePattern) == nil { throw ProjectError.invalidPortName(p) }
        for s in req.services { _ = try await services.recipe(s) }

        // Reserve a block of 10 ports (3100–3109, 3110–3119, …) not used by other projects and free right now.
        let used = Set(state.projects.flatMap { $0.ports.values }).union(state.sites.map(\.port))
        guard let base = stride(from: 3100, to: 9000, by: 10).first(where: { b in
            (b..<(b + portNames.count)).allSatisfy { !used.contains($0) && Sockets.isFree(port: $0) }
        }) else { throw ProjectError.noPorts }
        let ports = Dictionary(uniqueKeysWithValues: portNames.enumerated().map { ($1, base + $0) })

        // Resources first, so a failure leaves nothing half-registered.
        for id in req.services {
            let r = try await services.recipe(id)
            // Every chosen service should be running for the project, even ones without a resource (Redis, Mailpit).
            if try await services.status(id).state != .running {
                try await services.start(id)
                try await services.waitHealthy(id)
            }
            guard let kindID = r.projectResource, let kind = r.resourceKind(kindID), let create = kind.create else { continue }
            let res = try await services.runAction(id, create, params: ["name": name])
            guard res.ok else { throw ProjectError.resourceFailed(id, res.output) }
        }

        for (portName, port) in ports {
            try await hosts.addSite(name: Self.siteName(project: name, port: portName, first: portName == portNames[0]), port: port)
        }
        let project = SpaceState.Project(name: name, services: req.services, ports: ports)
        state = SpaceState.load()
        state.projects.append(project)
        try state.save()
        return try await view(project)
    }

    public func delete(_ name: String, dropData: Bool) async throws {
        var state = SpaceState.load()
        guard let p = state.projects.first(where: { $0.name == name }) else { throw ProjectError.notFound(name) }
        if dropData {
            for id in p.services {
                guard let r = try? await services.recipe(id), let kindID = r.projectResource,
                      let drop = r.resourceKind(kindID)?.drop,
                      try await services.status(id).state == .running else { continue }
                _ = try? await services.runAction(id, drop, params: ["name": name])
            }
        }
        let first = p.ports.min { $0.value < $1.value }?.key
        for portName in p.ports.keys {
            try? await hosts.removeSite(Self.siteName(project: name, port: portName, first: portName == first))
        }
        state = SpaceState.load()
        state.projects.removeAll { $0.name == name }
        try state.save()
    }

    static func siteName(project: String, port: String, first: Bool) -> String {
        first ? project : "\(port).\(project)"
    }

    private func view(_ p: SpaceState.Project) async throws -> ProjectView {
        let ordered = p.ports.sorted { $0.value < $1.value }
        let first = ordered.first?.key
        var hostsByPort: [String: String] = [:]
        for (portName, _) in ordered {
            hostsByPort[portName] = "\(Self.siteName(project: p.name, port: portName, first: portName == first)).\(Hostnames.domain)"
        }
        var recipes: [Recipe] = []
        for id in p.services { if let r = try? await services.recipe(id) { recipes.append(r) } }
        return ProjectView(name: p.name, services: p.services, ports: p.ports, hosts: hostsByPort,
                           env: Self.env(project: p, hosts: hostsByPort, recipes: recipes))
    }

    /// PORT / APP_URL for the first port, `<NAME>_PORT` / `<NAME>_URL` for the rest, then each service's template.
    static func env(project p: SpaceState.Project, hosts: [String: String], recipes: [Recipe]) -> String {
        var lines = ["# \(p.name) — generated by Space"]
        let ordered = p.ports.sorted { $0.value < $1.value }
        for (i, (portName, port)) in ordered.enumerated() {
            let key = portName.uppercased().replacingOccurrences(of: "-", with: "_")
            lines.append(i == 0 ? "PORT=\(port)" : "\(key)_PORT=\(port)")
            if let host = hosts[portName] { lines.append(i == 0 ? "APP_URL=http://\(host)" : "\(key)_URL=http://\(host)") }
        }
        for r in recipes {
            guard let tmpl = r.projectEnv, !tmpl.isEmpty else { continue }
            lines.append("")
            lines.append("# \(r.name)")
            for (k, v) in tmpl.sorted(by: { $0.key < $1.key }) {
                lines.append("\(k)=\(r.expand(v).replacingOccurrences(of: "{name}", with: p.name))")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

public enum ProjectError: Error, CustomStringConvertible {
    case invalidName(String), invalidPortName(String), exists(String), notFound(String), noPorts
    case resourceFailed(String, String)
    public var description: String {
        switch self {
        case .invalidName(let n): "'\(n)' isn't a valid project name (3–42 lowercase letters, digits or hyphens)"
        case .invalidPortName(let n): "'\(n)' isn't a valid port name"
        case .exists(let n): "Project '\(n)' already exists"
        case .notFound(let n): "No project named '\(n)'"
        case .noPorts: "No free port block found"
        case .resourceFailed(let s, let out): "Couldn't create the \(s) resource: \(out)"
        }
    }
}
