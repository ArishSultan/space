import Darwin
import Foundation
import System

public enum NativeError: Error, CustomStringConvertible {
    case notInstalled(String)
    case stillRunning(String)
    public var description: String {
        switch self {
        case .notInstalled(let name): "\(name) isn't installed on this Mac. Use Install in Space (or `spaced install \(name.lowercased())`), then start it."
        case .stillRunning(let name): "\(name) is still running — it may be managed by its own app. Quit it from that app's menu bar icon."
        }
    }
}

/// How a natively-run service is installed on this Mac, and what Space can do about it.
public struct NativeInstall: Codable, Sendable, Hashable {
    public enum Source: String, Codable, Sendable {
        /// Installed by Homebrew (`brew install`): Space can update it.
        case brew
        /// Inside an app bundle (e.g. Ollama.app): the app updates itself.
        case app
        /// Somewhere else (built from source, another package manager).
        case other
        case none
    }
    public let source: Source
    public let path: String?
    public let brewAvailable: Bool
    /// Homebrew formula Space installs with.
    public let formula: String?
    public let downloadURL: String?
    /// An install or update is running right now.
    public let installing: Bool
    /// Why the last install or update failed.
    public let error: String?

    public var installed: Bool { source != .none }
    public var canInstall: Bool { source == .none && brewAvailable && formula != nil }
    public var canUpdate: Bool { source == .brew && brewAvailable }

    /// Follows symlinks first: `/usr/local/bin/ollama` is usually a link into Ollama.app or the Homebrew Cellar.
    public static func classify(_ path: String?) -> Source {
        guard let path else { return .none }
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        if real.contains("/Cellar/") { return .brew }
        if real.contains(".app/") { return .app }
        return .other
    }
}

/// Starts, stops and inspects services that run as plain macOS processes (see `Recipe.Native`).
/// A pid file lets a restarted `spaced` find and stop a process it started earlier.
public actor NativeProcesses {
    private var children: [String: Process] = [:]
    public init() {}

    public static var logsDirectory: URL { SpacePaths.root.appending(path: "logs") }
    static var runDirectory: URL { SpacePaths.root.appending(path: "run") }
    public static func logURL(_ id: String) -> URL { logsDirectory.appending(path: "\(id).log") }
    static func pidURL(_ id: String) -> URL { runDirectory.appending(path: "\(id).pid") }

    public static func executable(for native: Recipe.Native) -> String? {
        native.executables.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Any HTTP answer below 500 means the service is up. Fast (loopback), and never keeps a connection open.
    public static func probe(_ url: URL) async -> Bool {
        var req = URLRequest(url: url, timeoutInterval: 1.5)
        req.setValue("close", forHTTPHeaderField: "Connection")
        guard let (_, resp) = try? await URLSession(configuration: .ephemeral).data(for: req) else { return false }
        return ((resp as? HTTPURLResponse)?.statusCode ?? 500) < 500
    }

    // MARK: Installing

    public static func locateBrew() -> String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private enum Job { case running, finished(error: String?) }
    private var jobs: [String: Job] = [:]

    /// Marks an install/update as running; false when one already is.
    func beginJob(_ id: String) -> Bool {
        if case .running = jobs[id] { return false }
        jobs[id] = .running
        return true
    }

    func finishJob(_ id: String, error: String?) { jobs[id] = .finished(error: error) }

    func jobState(_ id: String) -> (running: Bool, error: String?) {
        switch jobs[id] {
        case .running: (true, nil)
        case .finished(let error): (false, error)
        case nil: (false, nil)
        }
    }

    /// Runs `brew <verb> <formula>`; returns an error message, or nil on success. Output goes to logs/<id>-install.log.
    public static func brew(_ verb: String, formula: String, id: String) async -> String? {
        guard let brew = locateBrew() else { return "Homebrew isn't installed." }
        guard let r = try? await ProcessRunner.run(FilePath(brew), [verb, formula]) else { return "Couldn't run Homebrew." }
        try? FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        try? (r.stdout + r.stderr).write(to: logsDirectory.appending(path: "\(id)-install.log"), atomically: true, encoding: .utf8)
        guard !r.ok else { return nil }
        let tail = (r.stderr.isEmpty ? r.stdout : r.stderr).split(separator: "\n").suffix(6).joined(separator: "\n")
        return "brew \(verb) \(formula) failed:\n\(tail)"
    }

    // MARK: Lifecycle

    public func start(id: String, name: String, native: Recipe.Native, env: [String: String]) throws {
        guard let exe = Self.executable(for: native) else { throw NativeError.notInstalled(name) }
        let fm = FileManager.default
        try fm.createDirectory(at: Self.logsDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: Self.runDirectory, withIntermediateDirectories: true)
        let log = Self.logURL(id)
        // Keep the log bounded: start over once it passes 10 MB.
        if let size = (try? fm.attributesOfItem(atPath: log.path)[.size] as? Int), size > 10_000_000 { try? fm.removeItem(at: log) }
        if !fm.fileExists(atPath: log.path) { fm.createFile(atPath: log.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()

        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = native.args ?? []
        p.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = handle
        p.standardError = handle
        try p.run()
        children[id] = p
        try? String(p.processIdentifier).write(to: Self.pidURL(id), atomically: true, encoding: .utf8)
    }

    /// Stops the process listening on `port` (SIGTERM), waiting for the port to close.
    public func stop(id: String, name: String, executableName: String, probeURL: URL, port: Int) async throws {
        guard let pid = await pid(id: id, executableName: executableName, port: port) else { return }
        kill(pid, SIGTERM)
        for _ in 0..<50 {
            if kill(pid, 0) != 0, !(await Self.probe(probeURL)) { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        children[id] = nil
        if await Self.probe(probeURL) { throw NativeError.stillRunning(name) }
        try? FileManager.default.removeItem(at: Self.pidURL(id))
    }

    /// The pid of our process: from the pid file, else whatever listens on the port. Only returns a process
    /// whose name matches `executableName`, so a stale pid file or an unrelated listener is never signalled.
    public func pid(id: String, executableName: String, port: Int) async -> Int32? {
        if let text = try? String(contentsOf: Self.pidURL(id), encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
           kill(pid, 0) == 0, await Self.processName(pid) == executableName {
            return pid
        }
        let r = try? await ProcessRunner.run("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"])
        for line in (r?.stdout ?? "").split(separator: "\n") {
            if let pid = Int32(line), await Self.processName(pid) == executableName { return pid }
        }
        return nil
    }

    static func processName(_ pid: Int32) async -> String? {
        let r = try? await ProcessRunner.run("/bin/ps", ["-p", String(pid), "-o", "comm="])
        return r.flatMap { URL(fileURLWithPath: $0.stdout.trimmingCharacters(in: .whitespacesAndNewlines)).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: Inspection

    /// CPU percent (of one core) and resident memory, as reported by `ps`.
    public static func usage(pid: Int32) async -> (cpu: Double, rss: UInt64)? {
        let r = try? await ProcessRunner.run("/bin/ps", ["-p", String(pid), "-o", "%cpu=,rss="])
        let f = (r?.stdout ?? "").split(whereSeparator: \.isWhitespace)
        guard f.count == 2, let cpu = Double(f[0]), let kb = UInt64(f[1]) else { return nil }
        return (cpu, kb * 1024)
    }

    /// Established connections to the process's port, e.g. "2 connections".
    public static func connections(pid: Int32, port: Int) async -> Int {
        let r = try? await ProcessRunner.run("/usr/sbin/lsof", ["-nP", "-a", "-p", String(pid), "-iTCP:\(port)", "-sTCP:ESTABLISHED", "-Fn"])
        return (r?.stdout ?? "").split(separator: "\n").filter { $0.hasPrefix("n") }.count
    }

    public static func tailLog(_ id: String, lines: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: logURL(id)) else {
            return "No log yet: this service wasn't started by Space (or hasn't run yet).\n"
        }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 1_000_000 ? size - 1_000_000 : 0)
        let text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines + 1).joined(separator: "\n")
    }

    public static func followLog(_ id: String, tail: Int) -> AsyncThrowingStream<String, any Error> {
        try? FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logURL(id).path) { FileManager.default.createFile(atPath: logURL(id).path, contents: nil) }
        return ProcessRunner.lines("/usr/bin/tail", ["-n", String(tail), "-F", logURL(id).path])
    }
}
