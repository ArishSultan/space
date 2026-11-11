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
        /// Parameter names; values are substituted as `{name}`. Identifier-safe values only, except params
        /// listed in `text`: URL-encoded for HTTP actions, passed as-is for commands. Only list a param in
        /// `text` when it becomes its own argv element (never inside SQL, JS or a shell string).
        public var params: [String]?
        public var text: [String]?
        /// Command run inside the service container (or in `image`).
        public var exec: [String]?
        /// Run in a throwaway container of this image instead of inside the service
        /// (for services whose image has no CLI). `{address}` expands to the service's IP.
        public var image: String?
        public var env: [String: String]?
        /// Call the service's HTTP API from spaced instead of running a command.
        public var http: HTTPCall?
        /// For JSON output: `array[].field` turns the response into one line per element.
        public var extract: String?
        /// Hidden from the app's generic action buttons (used internally, e.g. by resources).
        public var hidden: Bool?
    }

    public struct HTTPCall: Codable, Sendable, Hashable {
        public var method: String?
        /// e.g. `http://localhost:{port.http}/api/v1/messages`
        public var url: String
    }

    /// An action on another service, run before this one starts (e.g. create its database).
    public struct Step: Codable, Sendable, Hashable {
        public var service: String
        public var action: String
        public var params: [String: String]?
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
    /// Shared services that must be running first (started, never stopped, by this one).
    public var dependsOn: [String]?
    /// Private helper services of a stack: started before and stopped together with this one, hidden in the app.
    public var parts: [String]?
    /// Hidden from the app's list (stack parts).
    public var hidden: Bool?
    /// Run before the first start, e.g. creating this stack's database in Postgres. Failures like "already exists" are ignored.
    public var prepare: [Step]?
    /// Actions run before pulling a new image (e.g. a backup).
    public var beforeUpdate: [String]?
    /// Extra `container run` arguments (e.g. ulimits).
    public var args: [String]?
    /// Environment variables this service contributes to a project's .env; `{name}` = project name.
    public var projectEnv: [String: String]?
    /// Resource kind (id) created for each project that uses this service, e.g. `projects` or `buckets`.
    public var projectResource: String?
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

    /// Expands `{port.<name>}` and `{gateway}` (the host as seen from containers) placeholders.
    public func expand(_ template: String, gateway: String = Recipe.defaultGateway) -> String {
        var out = template.replacingOccurrences(of: "{gateway}", with: gateway)
        for p in ports { out = out.replacingOccurrences(of: "{port.\(p.name)}", with: String(p.host)) }
        return out
    }

    public static let defaultGateway = "192.168.64.1"

    public var connectionInfo: [String: String] {
        (connection ?? [:]).mapValues { expand($0) }
    }
}

public enum ActionError: Error, CustomStringConvertible {
    case unknownAction(String)
    case missingParam(String)
    case invalidParam(String, String)
    case failed(String)
    case protected(String)
    case notAnHTTPAction

    public var description: String {
        switch self {
        case .unknownAction(let a): "Unknown action '\(a)'"
        case .missingParam(let p): "Missing parameter '\(p)'"
        case .invalidParam(let p, let v): "Invalid value '\(v)' for '\(p)': use letters, digits, '_' or '-'"
        case .failed(let output): output
        case .protected(let name): "'\(name)' is a built-in resource and can't be removed"
        case .notAnHTTPAction: "Action has neither a command nor an HTTP call"
        }
    }
}

extension Recipe.Action {
    /// Identifiers only — params land inside SQL/shell, so we keep them strictly safe.
    static var paramPattern: Regex<Substring> { /^[A-Za-z0-9_][A-Za-z0-9_-]{0,62}$/ }

    private func resolve(_ values: [String: String], urlEncodeText: Bool) throws -> [String: String] {
        var resolved: [String: String] = [:]
        for p in params ?? [] {
            guard let v = values[p], !v.isEmpty else { throw ActionError.missingParam(p) }
            if (text ?? []).contains(p) {
                resolved[p] = urlEncodeText
                    ? v.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+?#"))) ?? ""
                    : v
            } else {
                guard v.wholeMatch(of: Self.paramPattern) != nil else { throw ActionError.invalidParam(p, v) }
                resolved[p] = v
            }
        }
        return resolved
    }

    private func fill(_ s: String, _ resolved: [String: String]) -> String {
        resolved.reduce(s) { $0.replacingOccurrences(of: "{\($1.key)}", with: $1.value) }
    }

    public func command(with values: [String: String]) throws -> [String] {
        let resolved = try resolve(values, urlEncodeText: false)
        return (exec ?? []).map { fill($0, resolved) }
    }

    public func url(with values: [String: String]) throws -> String {
        guard let http else { throw ActionError.notAnHTTPAction }
        return fill(http.url, try resolve(values, urlEncodeText: true))
    }

    /// Applies `extract` to JSON output: `array[].field` or `array[].{a} {b.c} — {d}` (template with dotted keys)
    /// gives one line per element. Returns the output unchanged otherwise.
    public func extracted(_ output: String) -> String {
        guard let extract, let range = extract.range(of: "[]."),
              let json = try? JSONSerialization.jsonObject(with: Data(output.utf8)) else { return output }
        let arrayKey = String(extract[..<range.lowerBound]), field = String(extract[range.upperBound...])
        let array = (arrayKey.isEmpty ? json : (json as? [String: Any])?[arrayKey]) as? [[String: Any]] ?? []
        func value(_ obj: [String: Any], _ path: String) -> String {
            var cur: Any? = obj
            for key in path.split(separator: ".") { cur = (cur as? [String: Any])?[String(key)] }
            if let arr = cur as? [[String: Any]] { return arr.compactMap { $0["Address"] as? String }.joined(separator: ", ") }
            return cur.map { "\($0)" } ?? ""
        }
        guard field.contains("{") else { return array.map { value($0, field) }.joined(separator: "\n") }
        let keys = field.matches(of: /\{([A-Za-z0-9_.]+)\}/).map { String($0.1) }
        return array.map { obj in keys.reduce(field) { $0.replacingOccurrences(of: "{\($1)}", with: value(obj, $1)) } }
            .joined(separator: "\n")
    }
}
