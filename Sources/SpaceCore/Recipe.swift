import Foundation

/// A service definition loaded from YAML. One recipe = one running instance (latest version only).
public struct Recipe: Codable, Sendable, Identifiable, Hashable {
    public struct Port: Codable, Sendable, Hashable {
        public var name: String
        public var container: Int
        public var host: Int
    }

    public struct Volume: Codable, Sendable, Hashable {
        public var name: String
        public var path: String
    }

    public struct Health: Codable, Sendable, Hashable {
        public var exec: [String]
    }

    public struct Action: Codable, Sendable, Hashable {
        public var description: String
        /// Parameter names; values are substituted into `exec` as `{name}`.
        public var params: [String]?
        public var exec: [String]
        /// Run in a throwaway container of this image instead of inside the service
        /// (for services whose image has no CLI). `{address}` expands to the service's IP.
        public var image: String?
        public var env: [String: String]?
    }

    public var id: String
    public var name: String
    public var image: String
    public var ports: [Port]
    public var volumes: [Volume]?
    public var env: [String: String]?
    /// Run the container as this user (e.g. "0" when the image's user can't write to fresh volumes).
    public var user: String?
    public var memory: String?
    public var cpus: Int?
    public var health: Health?
    public var adminURL: String?
    /// SF Symbol name and accent colour (hex) used by the app.
    public var icon: String?
    public var color: String?
    /// Official logo image file, relative to the recipe file (falls back to the built-in recipes folder).
    public var logo: String?
    /// Connection strings keyed by label, with `{port.<name>}` placeholders.
    public var connection: [String: String]?
    public var dependsOn: [String]?
    /// Optional action listing connected clients, one per line (more detail than the generic TCP count).
    public var clients: String?
    public var actions: [String: Action]?
    /// "Things inside this service" (projects, databases, users, buckets) built from actions.
    public var resources: [Resources]?

    public func resourceKind(_ id: String) -> Resources? { resources?.first { $0.id == id } }

    public struct Resources: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        /// Singular noun shown in the UI, e.g. "database".
        public var kind: String
        /// Section title, e.g. "Databases".
        public var title: String
        /// Short explanation shown above the list.
        public var hint: String?
        /// Action returning one resource name per line.
        public var list: String
        public var create: String?
        public var drop: String?
        /// Names that must not be dropped from the UI (e.g. built-in databases).
        public var protected: [String]?
        /// Per-resource connection string; `{name}` and `{port.<name>}` placeholders.
        public var connection: String?
    }

    public var containerName: String { "space-\(id)" }

    public func volumeName(_ v: Volume) -> String { "space-\(id)-\(v.name)" }

    public func hostPort(_ name: String) -> Int? { ports.first { $0.name == name }?.host }

    /// Expands `{port.<name>}` placeholders.
    public func expand(_ template: String) -> String {
        var out = template
        for p in ports { out = out.replacingOccurrences(of: "{port.\(p.name)}", with: String(p.host)) }
        return out
    }

    public var connectionInfo: [String: String] {
        (connection ?? [:]).mapValues(expand)
    }
}

public enum ActionError: Error, CustomStringConvertible {
    case unknownAction(String)
    case missingParam(String)
    case invalidParam(String, String)
    case failed(String)
    case protected(String)

    public var description: String {
        switch self {
        case .unknownAction(let a): "Unknown action '\(a)'"
        case .missingParam(let p): "Missing parameter '\(p)'"
        case .invalidParam(let p, let v): "Invalid value '\(v)' for '\(p)': use letters, digits, '_' or '-'"
        case .failed(let output): output
        case .protected(let name): "'\(name)' is a built-in resource and can't be removed"
        }
    }
}

extension Recipe.Action {
    /// Identifiers only — params land inside SQL/shell, so we keep them strictly safe.
    static var paramPattern: Regex<Substring> { /^[A-Za-z0-9_][A-Za-z0-9_-]{0,62}$/ }

    public func command(with values: [String: String]) throws -> [String] {
        var resolved: [String: String] = [:]
        for p in params ?? [] {
            guard let v = values[p], !v.isEmpty else { throw ActionError.missingParam(p) }
            guard v.wholeMatch(of: Self.paramPattern) != nil else { throw ActionError.invalidParam(p, v) }
            resolved[p] = v
        }
        return exec.map { arg in
            resolved.reduce(arg) { $0.replacingOccurrences(of: "{\($1.key)}", with: $1.value) }
        }
    }
}
