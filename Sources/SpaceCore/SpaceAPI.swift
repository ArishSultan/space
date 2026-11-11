import Foundation

/// Client for the `spaced` HTTP API. Used by the CLI and the menu-bar app.
public struct SpaceAPI: Sendable {
    public static let defaultPort = Int(ProcessInfo.processInfo.environment["SPACE_PORT"] ?? "") ?? 7777

    public let base: URL
    let session: URLSession

    public init(port: Int = SpaceAPI.defaultPort, session: URLSession = .shared) {
        base = URL(string: "http://127.0.0.1:\(port)/api/")!
        self.session = session
    }

    /// Talks to another Mac's Space through the local daemon's tailnet proxy.
    public static func remote(peer: String, port: Int = SpaceAPI.defaultPort) -> SpaceAPI {
        SpaceAPI(base: URL(string: "http://127.0.0.1:\(port)/api/peers/\(peer)/proxy/")!)
    }

    public init(base: URL, session: URLSession = .shared) {
        self.base = base
        self.session = session
    }

    public enum Failure: Error, LocalizedError, CustomStringConvertible {
        case daemonNotRunning
        case server(String)
        public var description: String {
            switch self {
            case .daemonNotRunning: "Space service isn't running."
            case .server(let m): m
            }
        }
        public var errorDescription: String? { description }
    }

    private struct APIError: Decodable { struct Inner: Decodable { let message: String }; let error: Inner }

    public func get<T: Decodable>(_ path: String, query: [String: String] = [:], as: T.Type = T.self) async throws -> T {
        try await call("GET", path, query: query)
    }

    @discardableResult
    public func post<T: Decodable>(_ path: String, body: (any Encodable)? = nil, as: T.Type = T.self) async throws -> T {
        try await call("POST", path, body: body)
    }

    @discardableResult
    public func delete<T: Decodable>(_ path: String, as: T.Type = T.self) async throws -> T {
        try await call("DELETE", path)
    }

    public func call<T: Decodable>(_ method: String, _ path: String, query: [String: String] = [:], body: (any Encodable)? = nil) async throws -> T {
        let data = try await raw(method, path, query: query, body: body)
        if T.self == String.self { return String(decoding: data, as: UTF8.self) as! T }
        return try Self.decoder.decode(T.self, from: data)
    }

    /// Hummingbird encodes dates as ISO-8601.
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public func raw(_ method: String, _ path: String, query: [String: String] = [:], body: (any Encodable)? = nil) async throws -> Data {
        var url = base.appending(path: path)
        if !query.isEmpty { url.append(queryItems: query.map { URLQueryItem(name: $0.key, value: $0.value) }) }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 120
        if let body {
            req.httpBody = try JSONEncoder().encode(body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: req) }
        catch let e as URLError where [.cannotConnectToHost, .networkConnectionLost, .cannotFindHost].contains(e.code) {
            throw Failure.daemonNotRunning
        }
        guard let http = response as? HTTPURLResponse, http.statusCode < 300 else {
            let msg = (try? JSONDecoder().decode(APIError.self, from: data).error.message) ?? String(decoding: data, as: UTF8.self)
            throw Failure.server(msg)
        }
        return data
    }

    public func isUp() async -> Bool {
        (try? await raw("GET", "net")) != nil
    }
}
