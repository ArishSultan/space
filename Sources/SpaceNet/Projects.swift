import Foundation
import SpaceCore

/// A project is one app you're building: named **endpoints** (a port + a `*.localhost` hostname each) and plain
/// **references** to the resources it uses (a database, a bucket, Redis…). References are like foreign keys:
/// they let you (and agents) see what an app uses and generate its `.env`, but a project never owns data —
/// deleting a project, or a resource, never deletes the other.
public actor Projects {
    let services: ServiceManager
    let hosts: Hostnames

    public init(services: ServiceManager, hosts: Hostnames) {
        self.services = services
        self.hosts = hosts
    }

    static var namePattern: Regex<Substring> { /^[a-z0-9][a-z0-9-]{1,40}[a-z0-9]$/ }
    static var endpointPattern: Regex<Substring> { /^[a-z][a-z0-9-]{0,20}$/ }

    // MARK: Routing

    /// Publishes every project endpoint as a hostname. Called at startup and after each change.
    public func sync() async {
        let sites = SpaceState.load().projects.flatMap { p in
            p.endpoints.map { (name: $0.hostname, port: $0.port, project: p.name) }
        }
        await hosts.setProjectSites(sites)
    }

    // MARK: Reading

    public func list() async throws -> [ProjectView] {
        var out: [ProjectView] = []
        for p in SpaceState.load().projects.sorted(by: { $0.name < $1.name }) { out.append(try await view(p, checkMissing: false)) }
        return out
    }

    public func get(_ name: String) async throws -> ProjectView {
        try await view(try find(name), checkMissing: true)
    }

    private func find(_ name: String) throws -> SpaceState.Project {
        guard let p = SpaceState.load().projects.first(where: { $0.name == name }) else { throw ProjectError.notFound(name) }
        return p
    }

    // MARK: Projects

    public func create(_ req: ProjectRequest) async throws -> ProjectView {
        let name = req.name.lowercased()
        guard name.wholeMatch(of: Self.namePattern) != nil else { throw ProjectError.invalidName(req.name) }
        var state = SpaceState.load()
        guard !state.projects.contains(where: { $0.name == name }) else { throw ProjectError.exists(name) }

        // Validate everything that can be checked up front, so a typo doesn't leave a half-made project.
        var project = SpaceState.Project(name: name)
        var taken = takenHostnames(in: state, except: nil).union(await hosts.serviceSiteNames())
        for e in req.endpoints ?? [] {
            let endpoint = try makeEndpoint(e, project: name, existing: project.endpoints, taken: taken)
            taken.insert(endpoint.hostname)
            project.endpoints.append(endpoint)
        }
        for link in req.resources ?? [] {
            let ref = try await resolve(link)
            if !project.resources.contains(ref) { project.resources.append(ref) }
        }

        state = SpaceState.load()
        state.projects.append(project)
        try state.save()
        await sync()
        return try await view(project, checkMissing: false)
    }

    /// Removes the project and its hostnames. Linked resources (databases, buckets…) are left alone.
    public func delete(_ name: String) async throws {
        var state = SpaceState.load()
        guard state.projects.contains(where: { $0.name == name }) else { throw ProjectError.notFound(name) }
        state.projects.removeAll { $0.name == name }
        try state.save()
        await sync()
    }

    // MARK: Endpoints

    public func addEndpoint(_ project: String, _ req: EndpointRequest) async throws -> ProjectView {
        var state = SpaceState.load()
        guard let i = state.projects.firstIndex(where: { $0.name == project }) else { throw ProjectError.notFound(project) }
        let taken = takenHostnames(in: state, except: nil).union(await hosts.serviceSiteNames())
        let endpoint = try makeEndpoint(req, project: project, existing: state.projects[i].endpoints, taken: taken)
        state.projects[i].endpoints.append(endpoint)
        try state.save()
        await sync()
        return try await view(state.projects[i], checkMissing: false)
    }

    public func removeEndpoint(_ project: String, _ endpoint: String) async throws -> ProjectView {
        var state = SpaceState.load()
        guard let i = state.projects.firstIndex(where: { $0.name == project }) else { throw ProjectError.notFound(project) }
        guard state.projects[i].endpoints.contains(where: { $0.name == endpoint }) else {
            throw ProjectError.endpointNotFound(project, endpoint)
        }
        state.projects[i].endpoints.removeAll { $0.name == endpoint }
        try state.save()
        await sync()
        return try await view(state.projects[i], checkMissing: false)
    }

    private func takenHostnames(in state: SpaceState, except project: String?) -> Set<String> {
        Set(state.projects.filter { $0.name != project }.flatMap { $0.endpoints.map(\.hostname) })
    }

    private func makeEndpoint(_ req: EndpointRequest, project: String, existing: [SpaceState.Endpoint],
                              taken: Set<String>) throws -> SpaceState.Endpoint {
        let label = req.name.lowercased()
        guard label.wholeMatch(of: Self.endpointPattern) != nil else { throw ProjectError.invalidEndpointName(req.name) }
        guard !existing.contains(where: { $0.name == label }) else { throw ProjectError.endpointExists(project, label) }
        guard (1...65535).contains(req.port), req.port != 80, req.port != 443, req.port != hosts.routerPort else {
            throw ProjectError.invalidPort(req.port)
        }
        let raw = req.hostname?.isEmpty == false ? req.hostname! : "\(label).\(project)"
        guard let hostname = Hostnames.normalize(raw) else { throw ProjectError.invalidHostname(raw) }
        guard !taken.contains(hostname), !existing.contains(where: { $0.hostname == hostname }) else {
            throw ProjectError.hostnameTaken(hostname)
        }
        return .init(name: label, port: req.port, hostname: hostname)
    }

    // MARK: Resource links

    /// Links a resource to the project, creating it first when `create` is set (starting its service if needed).
    public func addResource(_ project: String, _ link: ResourceLinkRequest) async throws -> ProjectView {
        _ = try find(project)
        let ref = try await resolve(link)
        var state = SpaceState.load()
        guard let i = state.projects.firstIndex(where: { $0.name == project }) else { throw ProjectError.notFound(project) }
        if !state.projects[i].resources.contains(ref) { state.projects[i].resources.append(ref) }
        try state.save()
        return try await view(state.projects[i], checkMissing: true)
    }

    /// Unlinks only; the database, bucket… stays.
    public func removeResource(_ project: String, _ link: ResourceLinkRequest) async throws -> ProjectView {
        var state = SpaceState.load()
        guard let i = state.projects.firstIndex(where: { $0.name == project }) else { throw ProjectError.notFound(project) }
        let ref = SpaceState.ResourceRef(service: link.service, kind: link.kind, name: link.name)
        guard state.projects[i].resources.contains(ref) else { throw ProjectError.linkNotFound(project, link.service) }
        state.projects[i].resources.removeAll { $0 == ref }
        try state.save()
        return try await view(state.projects[i], checkMissing: true)
    }

    /// Validates a link request and, with `create`, makes sure the target exists.
    private func resolve(_ link: ResourceLinkRequest) async throws -> SpaceState.ResourceRef {
        let recipe = try await services.recipe(link.service)
        let create = link.create == true
        let kinds = recipe.resources ?? []

        guard !kinds.isEmpty else {
            guard link.kind == nil, link.name == nil else { throw ProjectError.noSubItems(link.service) }
            if create { try await ensureRunning(link.service) }
            return .init(service: link.service)
        }
        guard let kindID = link.kind, let kind = recipe.resourceKind(kindID) else {
            throw ProjectError.unknownKind(link.service, link.kind ?? "", kinds.map(\.id))
        }
        guard let name = link.name, !name.isEmpty else { throw ProjectError.missingName(link.service, kind.id) }
        guard name.wholeMatch(of: Recipe.Action.paramPattern) != nil else { throw ProjectError.invalidResourceName(name) }

        let running = try await services.status(link.service).state == .running
        if create {
            try await ensureRunning(link.service)
            if try await !items(link.service, kind).contains(name) {
                guard let createAction = kind.create else { throw ProjectError.cantCreate(link.service, kind.id) }
                let out = try await services.runAction(link.service, createAction, params: ["name": name])
                guard out.ok else { throw ProjectError.resourceFailed(link.service, out.output) }
            }
        } else if running, try await !items(link.service, kind).contains(name) {
            throw ProjectError.resourceNotFound(link.service, kind.id, name)
        }
        return .init(service: link.service, kind: kind.id, name: name)
    }

    private func ensureRunning(_ id: String) async throws {
        if try await services.status(id).state != .running {
            try await services.start(id)
            try await services.waitHealthy(id)
        }
    }

    /// Names currently in a resource kind (its `list` action prints them separated by whitespace).
    private func items(_ service: String, _ kind: Recipe.Resources) async throws -> [String] {
        let out = try await services.runAction(service, kind.list)
        guard out.ok else { throw ProjectError.resourceFailed(service, out.output) }
        return out.output.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    // MARK: View

    private func view(_ p: SpaceState.Project, checkMissing: Bool) async throws -> ProjectView {
        let routerPort = hosts.routerPort
        let endpoints = p.endpoints.map { e -> EndpointView in
            let host = Hostnames.host(e.hostname)
            return EndpointView(name: e.name, port: e.port, host: host, url: Hostnames.url(host: host, routerPort: routerPort),
                                up: Hostnames.canConnect(e.port))
        }
        var recipes: [String: Recipe] = [:]
        var links: [ResourceLinkView] = []
        for ref in p.resources {
            guard let recipe = try? await services.recipe(ref.service) else {
                links.append(.init(service: ref.service, kind: ref.kind, name: ref.name, missing: true))
                continue
            }
            recipes[ref.service] = recipe
            var missing: Bool?
            if checkMissing, let kindID = ref.kind, let name = ref.name, let kind = recipe.resourceKind(kindID),
               (try? await services.status(ref.service).state) == .running,
               let names = try? await items(ref.service, kind) {
                missing = !names.contains(name)
            }
            links.append(.init(service: ref.service, kind: ref.kind, name: ref.name, missing: missing))
        }
        return ProjectView(name: p.name, endpoints: endpoints, resources: links,
                           env: Self.env(project: p, routerPort: routerPort, recipes: recipes))
    }

    /// PORT / APP_URL for the first endpoint, `<LABEL>_PORT` / `<LABEL>_URL` for the rest, then the settings of
    /// every linked resource. A second link that would reuse a variable name (two databases → `DATABASE_URL`)
    /// gets its resource name as a prefix, e.g. `ANALYTICS_DATABASE_URL`.
    static func env(project p: SpaceState.Project, routerPort: Int, recipes: [String: Recipe]) -> String {
        var lines = ["# \(p.name) — generated by Space"]
        for (i, e) in p.endpoints.enumerated() {
            let key = envKey(e.name)
            let url = Hostnames.url(host: Hostnames.host(e.hostname), routerPort: routerPort)
            lines.append(i == 0 ? "PORT=\(e.port)" : "\(key)_PORT=\(e.port)")
            lines.append(i == 0 ? "APP_URL=\(url)" : "\(key)_URL=\(url)")
        }
        var used = Set<String>()
        for ref in p.resources {
            guard let r = recipes[ref.service] else { continue }
            let template = ref.kind.flatMap { r.resourceKind($0)?.env } ?? (ref.kind == nil ? r.projectEnv : nil)
            guard let template, !template.isEmpty else { continue }
            var keys = template.keys.sorted()
            if keys.contains(where: used.contains) {
                guard let name = ref.name else { continue }
                keys = keys.map { "\(envKey(name))_\($0)" }
            }
            lines.append("")
            lines.append("# \(r.name)" + (ref.name.map { " — \($0)" } ?? ""))
            for (base, key) in zip(template.keys.sorted(), keys) {
                used.insert(key)
                let value = r.expand(template[base]!).replacingOccurrences(of: "{name}", with: ref.name ?? "")
                lines.append("\(key)=\(value)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func envKey(_ s: String) -> String {
        s.uppercased().replacingOccurrences(of: "-", with: "_")
    }
}

public enum ProjectError: Error, CustomStringConvertible {
    case invalidName(String), invalidEndpointName(String), invalidPort(Int), invalidHostname(String), invalidResourceName(String)
    case exists(String), notFound(String), endpointExists(String, String), endpointNotFound(String, String)
    case hostnameTaken(String), linkNotFound(String, String)
    case noSubItems(String), unknownKind(String, String, [String]), missingName(String, String)
    case cantCreate(String, String), resourceNotFound(String, String, String), resourceFailed(String, String)

    public var description: String {
        switch self {
        case .invalidName(let n): "'\(n)' isn't a valid project name (3–42 lowercase letters, digits or hyphens)"
        case .invalidEndpointName(let n): "'\(n)' isn't a valid endpoint name (lowercase letters, digits or hyphens, starting with a letter)"
        case .invalidPort(let p): "Port \(p) can't be used (1–65535, not 80 or 443)"
        case .invalidHostname(let h): "'\(h)' isn't a valid hostname (lowercase letters, digits, hyphens; dots for subdomains)"
        case .invalidResourceName(let n): "'\(n)' isn't a valid name (letters, digits, '_' or '-')"
        case .exists(let n): "Project '\(n)' already exists"
        case .notFound(let n): "No project named '\(n)'"
        case .endpointExists(let p, let e): "Project '\(p)' already has an endpoint '\(e)'"
        case .endpointNotFound(let p, let e): "Project '\(p)' has no endpoint '\(e)'"
        case .hostnameTaken(let h): "The hostname \(h).localhost is already in use"
        case .linkNotFound(let p, let s): "Project '\(p)' isn't linked to that \(s) resource"
        case .noSubItems(let s): "\(s) has no databases or buckets to link; link the service itself (leave out kind and name)"
        case .unknownKind(let s, let k, let valid): "\(s) has no resource kind '\(k)'. Use one of: \(valid.joined(separator: ", "))"
        case .missingName(let s, let k): "Say which \(s) \(k) item to link (name)"
        case .cantCreate(let s, let k): "\(s) can't create \(k) items"
        case .resourceNotFound(let s, let k, let n): "\(s) has no \(k) item '\(n)'. Pass create=true to make it"
        case .resourceFailed(let s, let out): "Couldn't create the \(s) resource: \(out)"
        }
    }
}
