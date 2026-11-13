import Foundation

// Ollama support: models (download, load into memory, unload, delete) and server settings.
// Ollama itself runs as a native process (Recipes/ollama.yaml); everything here talks to its HTTP API.

public struct OllamaModel: Codable, Sendable, Hashable, Identifiable {
    public let name: String
    /// Size on disk.
    public let sizeBytes: UInt64
    public let parameterSize: String?
    public let quantization: String?
    public let family: String?
    public let modifiedAt: Date?
    /// Loaded in memory right now: ready to answer without a load delay.
    public let loaded: Bool
    /// Loaded and kept in memory until unloaded (keep-alive forever).
    public let pinned: Bool
    /// A load is in progress.
    public let loading: Bool
    /// When an unpinned loaded model is unloaded again.
    public let expiresAt: Date?
    /// Memory the loaded model uses.
    public let memoryBytes: UInt64?
    /// Why the last load failed.
    public let error: String?
    public var id: String { name }
}

public struct OllamaPull: Codable, Sendable, Hashable, Identifiable {
    public let name: String
    public let status: String
    public let completedBytes: UInt64
    public let totalBytes: UInt64
    public let done: Bool
    public let error: String?
    public var id: String { name }
    public var fraction: Double? { totalBytes > 0 ? min(1, Double(completedBytes) / Double(totalBytes)) : nil }
}

/// Server settings, applied as environment variables the next time Ollama starts.
public struct OllamaSettings: Codable, Sendable, Equatable {
    /// OLLAMA_MAX_LOADED_MODELS: how many models stay in memory at once.
    public var maxLoadedModels: Int?
    /// OLLAMA_KEEP_ALIVE: how long an idle model stays loaded, e.g. "5m", "1h", "-1" (forever).
    public var keepAlive: String?
    /// OLLAMA_NUM_PARALLEL: simultaneous requests per model.
    public var numParallel: Int?

    public init(maxLoadedModels: Int? = nil, keepAlive: String? = nil, numParallel: Int? = nil) {
        self.maxLoadedModels = maxLoadedModels; self.keepAlive = keepAlive; self.numParallel = numParallel
    }

    func validated() throws -> OllamaSettings {
        var s = self
        for (label, value) in [("Max loaded models", s.maxLoadedModels), ("Parallel requests", s.numParallel)] {
            if let value, !(1...16).contains(value) { throw ActionError.failed("\(label) must be between 1 and 16") }
        }
        let keep = s.keepAlive?.trimmingCharacters(in: .whitespaces) ?? ""
        if keep.isEmpty { s.keepAlive = nil }
        else if keep.wholeMatch(of: /-?\d+[smh]?/) == nil { throw ActionError.failed("Keep-alive must look like 5m, 1h, 30s or -1 (forever)") }
        else { s.keepAlive = keep }
        return s
    }

    var environment: [String: String] {
        var env: [String: String] = [:]
        if let maxLoadedModels { env["OLLAMA_MAX_LOADED_MODELS"] = String(maxLoadedModels) }
        if let keepAlive { env["OLLAMA_KEEP_ALIVE"] = keepAlive }
        if let numParallel { env["OLLAMA_NUM_PARALLEL"] = String(numParallel) }
        return env
    }
}

public struct OllamaNameRequest: Codable, Sendable {
    public var name: String
    public init(name: String) { self.name = name }
}

struct OllamaError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// Settings and the models the user wants kept loaded, in their own file (state.json is owned by the network layer).
struct OllamaStore: Codable {
    var settings = OllamaSettings()
    var pinned: [String] = []

    init() {}
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        settings = try c.decodeIfPresent(OllamaSettings.self, forKey: .settings) ?? OllamaSettings()
        pinned = try c.decodeIfPresent([String].self, forKey: .pinned) ?? []
    }

    static var url: URL { SpacePaths.root.appending(path: "ollama.json") }
    static func load() -> OllamaStore {
        guard let data = try? Data(contentsOf: url) else { return OllamaStore() }
        return (try? JSONDecoder().decode(OllamaStore.self, from: data)) ?? OllamaStore()
    }
    func save() throws {
        try SpacePaths.ensure()
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(self).write(to: Self.url, options: .atomic)
    }
}

// MARK: - HTTP client

struct OllamaClient: Sendable {
    let base: URL

    struct Item: Decodable {
        struct Details: Decodable { let family: String?; let parameter_size: String?; let quantization_level: String? }
        let name: String
        let size: UInt64?
        let modified_at: String?
        let expires_at: String?
        let size_vram: UInt64?
        let details: Details?
    }

    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        // Ollama prints nanoseconds (".837531234-07:00"): drop the fraction.
        return f.date(from: s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression))
    }

    /// Keep-alive "forever" shows up as an expiry decades away (or the zero date).
    static func isPinned(expires: Date?) -> Bool {
        guard let expires else { return false }
        return expires.timeIntervalSinceNow > 30 * 86400 || expires.timeIntervalSince1970 < 0
    }

    func request(_ method: String, _ path: String, _ body: [String: Any]?, timeout: TimeInterval) throws -> URLRequest {
        var req = URLRequest(url: base.appending(path: path), timeoutInterval: timeout)
        req.httpMethod = method
        // No lingering keep-alive connection: it would show up as a connected client of Ollama.
        req.setValue("close", forHTTPHeaderField: "Connection")
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    static func errorMessage(_ data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
    }

    @discardableResult
    func send(_ method: String, _ path: String, _ body: [String: Any]? = nil, timeout: TimeInterval = 30) async throws -> Data {
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, resp) = try await session.data(for: try request(method, path, body, timeout: timeout))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code < 400 else { throw OllamaError(message: Self.errorMessage(data) ?? "Ollama answered HTTP \(code)") }
        return data
    }

    /// `/api/tags` (downloaded) or `/api/ps` (loaded).
    func models(_ path: String) async throws -> [Item] {
        struct List: Decodable { let models: [Item]? }
        return try JSONDecoder().decode(List.self, from: try await send("GET", path)).models ?? []
    }

    /// keep_alive -1 loads a model and keeps it; 0 unloads it. Embedding models have no `generate`.
    func setKeepAlive(_ name: String, _ value: Int) async throws {
        do {
            try await send("POST", "/api/generate", ["model": name, "keep_alive": value, "stream": false], timeout: 900)
        } catch let e as OllamaError where e.message.contains("does not support generate") {
            try await send("POST", "/api/embed", ["model": name, "input": " ", "keep_alive": value], timeout: 900)
        }
    }
}

// MARK: - Background work (downloads and loads)

/// Tracks model downloads and loads, which take minutes and outlive the HTTP request that started them.
public actor OllamaState {
    private var pulls: [String: OllamaPull] = [:]
    private var finishedAt: [String: Date] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var loading: Set<String> = []
    private var loadErrors: [String: String] = [:]

    public init() {}

    func snapshot() -> (loading: Set<String>, errors: [String: String]) { (loading, loadErrors) }

    func pullList() -> [OllamaPull] {
        for (name, at) in finishedAt where Date().timeIntervalSince(at) > 20 { pulls[name] = nil; finishedAt[name] = nil }
        return pulls.values.sorted { $0.name < $1.name }
    }

    func startPull(_ name: String, client: OllamaClient) {
        guard tasks[name] == nil else { return }
        pulls[name] = OllamaPull(name: name, status: "starting", completedBytes: 0, totalBytes: 0, done: false, error: nil)
        finishedAt[name] = nil
        tasks[name] = Task { await self.runPull(name, client) }
    }

    func cancelPull(_ name: String) {
        tasks[name]?.cancel()
    }

    private func runPull(_ name: String, _ client: OllamaClient) async {
        var layers: [String: (done: UInt64, total: UInt64)] = [:]
        func set(_ status: String, done: Bool = false, error: String? = nil) {
            pulls[name] = OllamaPull(name: name, status: status, completedBytes: layers.values.reduce(0) { $0 + $1.done },
                                     totalBytes: layers.values.reduce(0) { $0 + $1.total }, done: done, error: error)
        }
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        do {
            let req = try client.request("POST", "/api/pull", ["model": name, "stream": true], timeout: 600)
            let (bytes, resp) = try await session.bytes(for: req)
            if let code = (resp as? HTTPURLResponse)?.statusCode, code >= 400 {
                var body = Data()
                for try await b in bytes { body.append(b) }
                throw OllamaError(message: OllamaClient.errorMessage(body) ?? "Ollama answered HTTP \(code)")
            }
            for try await line in bytes.lines {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                if let message = obj["error"] as? String { throw OllamaError(message: message) }
                if let digest = obj["digest"] as? String, let total = (obj["total"] as? NSNumber)?.uint64Value {
                    layers[digest] = ((obj["completed"] as? NSNumber)?.uint64Value ?? 0, total)
                }
                set(obj["status"] as? String ?? "")
            }
            set("success", done: true)
        } catch is CancellationError {
            set("cancelled", done: true)
        } catch let e as URLError where e.code == .cancelled {
            set("cancelled", done: true)
        } catch {
            set("failed", done: true, error: String(describing: error))
        }
        finishedAt[name] = Date()
        tasks[name] = nil
    }

    func startLoad(_ name: String, client: OllamaClient) {
        guard !loading.contains(name) else { return }
        loading.insert(name)
        loadErrors[name] = nil
        Task { await self.runLoad(name, client) }
    }

    private func runLoad(_ name: String, _ client: OllamaClient) async {
        do { try await client.setKeepAlive(name, -1) } catch { loadErrors[name] = String(describing: error) }
        loading.remove(name)
    }

    func clearError(_ name: String) { loadErrors[name] = nil }
}

// MARK: - ServiceManager

extension ServiceManager {
    static func canonicalModelName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.count <= 200, name.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9._:\/@+-]*/) != nil else {
            throw ActionError.failed("'\(raw)' isn't a valid model name — use something like llama3.2 or qwen2.5:7b")
        }
        return (name.split(separator: "/").last?.contains(":") ?? false) ? name : name + ":latest"
    }

    func ollamaClient() throws -> OllamaClient {
        let r = try recipe("ollama")
        guard let port = r.hostPort("api") else { throw ServiceError.unknownService("ollama") }
        return OllamaClient(base: URL(string: "http://127.0.0.1:\(port)")!)
    }

    /// The client, once Ollama answers.
    func runningOllama() async throws -> OllamaClient {
        let client = try ollamaClient()
        guard await NativeProcesses.probe(client.base.appending(path: "/api/version")) else { throw ServiceError.notRunning("ollama") }
        return client
    }

    func ollamaEnvironment() throws -> [String: String] {
        let r = try recipe("ollama")
        var env = ["OLLAMA_HOST": "127.0.0.1:\(r.hostPort("api") ?? 11434)"]
        env.merge(OllamaStore.load().settings.environment) { _, new in new }
        return env
    }

    /// Loads the models the user pinned, after Ollama (re)starts.
    func ollamaRepin() async {
        guard let client = try? ollamaClient(), let downloaded = try? await client.models("/api/tags") else { return }
        var store = OllamaStore.load()
        // Models deleted outside Space (`ollama rm`) can't be loaded: forget them.
        let have = Set(downloaded.map(\.name))
        let missing = store.pinned.filter { !have.contains($0) }
        if !missing.isEmpty { store.pinned.removeAll { missing.contains($0) }; try? store.save() }
        for name in store.pinned { await ollama.startLoad(name, client: client) }
    }

    public func ollamaModels() async throws -> [OllamaModel] {
        let client = try await runningOllama()
        async let tags = client.models("/api/tags")
        async let ps = client.models("/api/ps")
        let (all, running) = try await (tags, ps)
        let byName = Dictionary(running.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let (loading, errors) = await ollama.snapshot()
        return all.map { m in
            let live = byName[m.name]
            let expires = live?.expires_at.flatMap(OllamaClient.parseDate)
            return OllamaModel(
                name: m.name, sizeBytes: m.size ?? 0, parameterSize: m.details?.parameter_size, quantization: m.details?.quantization_level,
                family: m.details?.family, modifiedAt: m.modified_at.flatMap(OllamaClient.parseDate),
                loaded: live != nil, pinned: live != nil && OllamaClient.isPinned(expires: expires), loading: loading.contains(m.name),
                expiresAt: OllamaClient.isPinned(expires: expires) ? nil : expires, memoryBytes: live?.size, error: errors[m.name])
        }
        .sorted { ($0.loaded ? 0 : 1, $0.name) < ($1.loaded ? 0 : 1, $1.name) }
    }

    public func ollamaPulls() async -> [OllamaPull] { await ollama.pullList() }

    public func ollamaPull(_ raw: String) async throws {
        let name = try Self.canonicalModelName(raw)
        await ollama.startPull(name, client: try await runningOllama())
    }

    public func ollamaCancelPull(_ raw: String) async throws {
        await ollama.cancelPull(try Self.canonicalModelName(raw))
    }

    /// Loads the model into memory and keeps it there (also after Ollama restarts) until unloaded.
    public func ollamaLoad(_ raw: String) async throws {
        let name = try Self.canonicalModelName(raw)
        let client = try await runningOllama()
        guard try await client.models("/api/tags").contains(where: { $0.name == name }) else {
            throw ActionError.failed("\(name) isn't downloaded yet — download it first.")
        }
        var store = OllamaStore.load()
        if !store.pinned.contains(name) { store.pinned.append(name); try store.save() }
        await ollama.startLoad(name, client: client)
    }

    public func ollamaUnload(_ raw: String) async throws {
        let name = try Self.canonicalModelName(raw)
        let client = try await runningOllama()
        var store = OllamaStore.load()
        store.pinned.removeAll { $0 == name }
        try store.save()
        await ollama.clearError(name)
        try await client.setKeepAlive(name, 0)
    }

    public func ollamaDelete(_ raw: String) async throws {
        let name = try Self.canonicalModelName(raw)
        let client = try await runningOllama()
        try? await ollamaUnload(name)
        do { try await client.send("DELETE", "/api/delete", ["model": name]) }
        catch let e as OllamaError { throw ActionError.failed(e.message) }
    }

    public func ollamaSettings() -> OllamaSettings { OllamaStore.load().settings }

    /// Saved now; Ollama reads them when it next starts.
    public func setOllamaSettings(_ settings: OllamaSettings) throws -> OllamaSettings {
        var store = OllamaStore.load()
        store.settings = try settings.validated()
        try store.save()
        return store.settings
    }
}
