import Foundation
import Observation
import System
import SpaceCore

/// One-click setup of Space's MCP server in Claude Code (CLI) and Claude Desktop.
@MainActor @Observable
final class AgentSetup {
    enum State: Equatable { case unknown, unavailable, notAdded, added }

    var claudeCode: State = .unknown
    var desktop: State = .unknown
    var busy = false
    var message: String?

    /// The bundled `spaced` binary the MCP clients launch (`spaced mcp`).
    static var spaced: String {
        Bundle.main.executableURL!.deletingLastPathComponent().appending(path: "spaced").path
    }

    static var desktopConfig: URL {
        URL.homeDirectory.appending(path: "Library/Application Support/Claude/claude_desktop_config.json")
    }

    private static func quoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Runs a command in the user's login shell so `claude` is found the way it is in Terminal.
    private func shell(_ command: String) async -> CommandResult? {
        try? await ProcessRunner.run(FilePath("/bin/zsh"), ["-lc", command])
    }

    func refresh() async {
        if let r = await shell("command -v claude >/dev/null 2>&1 && claude mcp get space >/dev/null 2>&1; echo $?; command -v claude >/dev/null 2>&1; echo $?") {
            let codes = r.stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            let found = codes.last == "0"
            claudeCode = !found ? .unavailable : (codes.first == "0" ? .added : .notAdded)
        } else {
            claudeCode = .unavailable
        }
        let hasApp = FileManager.default.fileExists(atPath: "/Applications/Claude.app")
            || FileManager.default.fileExists(atPath: Self.desktopConfig.deletingLastPathComponent().path)
        if !hasApp { desktop = .unavailable } else {
            desktop = (try? Self.readDesktopServers())?["space"] != nil ? .added : .notAdded
        }
    }

    // MARK: Claude Code

    func setClaudeCode(_ on: Bool) async {
        busy = true; message = nil
        defer { busy = false }
        // User scope, so it's available in every project (the CLI default is the current project only).
        let command = on
            ? "claude mcp remove space -s user >/dev/null 2>&1; claude mcp add -s user space -- \(Self.quoted(Self.spaced)) mcp"
            : "claude mcp remove space -s user"
        if let r = await shell(command), !r.ok {
            message = (r.stderr.isEmpty ? r.stdout : r.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if on {
            message = "Added to Claude Code. New sessions will have it."
        }
        await refresh()
    }

    // MARK: Claude Desktop

    private static func readDesktopConfig() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: desktopConfig), !data.isEmpty else { return [:] }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return obj
    }

    private static func readDesktopServers() throws -> [String: Any] {
        try readDesktopConfig()["mcpServers"] as? [String: Any] ?? [:]
    }

    func setDesktop(_ on: Bool) async {
        busy = true; message = nil
        defer { busy = false }
        do {
            var config = try Self.readDesktopConfig()
            var servers = config["mcpServers"] as? [String: Any] ?? [:]
            if on { servers["space"] = ["command": Self.spaced, "args": ["mcp"]] } else { servers["space"] = nil }
            config["mcpServers"] = servers
            let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try FileManager.default.createDirectory(at: Self.desktopConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: Self.desktopConfig, options: .atomic)
            message = on ? "Added to Claude Desktop. Quit and reopen it to load Space." : nil
        } catch {
            message = "Couldn't update Claude Desktop's config: \(error.localizedDescription)"
        }
        await refresh()
    }
}
