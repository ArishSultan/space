import ArgumentParser
import Foundation
import SpaceCore

struct OllamaCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ollama",
        abstract: "Ollama models: download, load into memory (on), unload (off), delete",
        subcommands: [OllamaList.self, OllamaPullCommand.self, OllamaLoad.self, OllamaUnload.self, OllamaRemove.self, OllamaSettingsCommand.self],
        defaultSubcommand: OllamaList.self
    )
}

struct ModelArg: ParsableArguments {
    @Argument(help: "Model name, e.g. llama3.2 or qwen2.5:7b") var model: String
}

func gigabytes(_ bytes: UInt64) -> String { String(format: "%.1f GB", Double(bytes) / 1_000_000_000) }

struct OllamaList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ls", abstract: "Downloaded models and which are loaded")
    @OptionGroup var out: JSONFlag
    func run() async throws {
        let models: [OllamaModel] = try await Daemon().get("ollama/models")
        if out.json { return try printJSON(models) }
        if models.isEmpty { print("No models. Download one: spaced ollama pull llama3.2") }
        for m in models {
            let state = m.loading ? "loading" : m.pinned ? "on (pinned)" : m.loaded ? "on" : "off"
            print("\(m.name.padding(toLength: 32, withPad: " ", startingAt: 0)) \(gigabytes(m.sizeBytes).padding(toLength: 9, withPad: " ", startingAt: 0)) \(state)\(m.error.map { "  — \($0)" } ?? "")")
        }
        let pulls: [OllamaPull] = try await Daemon().get("ollama/pulls")
        for p in pulls { print("downloading \(p.name): \(p.fraction.map { "\(Int($0 * 100))%" } ?? p.status)\(p.error.map { " — \($0)" } ?? "")") }
    }
}

struct OllamaPullCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "pull", abstract: "Download a model (shows progress until done)")
    @OptionGroup var arg: ModelArg
    func run() async throws {
        let daemon = Daemon()
        try await daemon.post("ollama/models/pull", body: OllamaNameRequest(name: arg.model)) as OKReply
        let name = arg.model.contains(":") ? arg.model : arg.model + ":latest"
        while true {
            try await Task.sleep(for: .seconds(1))
            let pulls: [OllamaPull] = try await daemon.get("ollama/pulls")
            guard let p = pulls.first(where: { $0.name == name }) else { return print("done") }
            print("\r\(p.fraction.map { "\(Int($0 * 100))%" } ?? p.status)   ", terminator: "")
            if p.done {
                print()
                if let e = p.error { throw ValidationError(e) }
                return print(p.status)
            }
        }
    }
}

struct OllamaLoad: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "load", abstract: "Turn a model on: load it into memory and keep it there")
    @OptionGroup var arg: ModelArg
    func run() async throws {
        try await Daemon().post("ollama/models/load", body: OllamaNameRequest(name: arg.model)) as OKReply
        print("loading \(arg.model) — check with `spaced ollama ls`")
    }
}

struct OllamaUnload: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "unload", abstract: "Turn a model off: free its memory (stays downloaded)")
    @OptionGroup var arg: ModelArg
    func run() async throws {
        try await Daemon().post("ollama/models/unload", body: OllamaNameRequest(name: arg.model)) as OKReply
        print("unloaded \(arg.model)")
    }
}

struct OllamaRemove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rm", abstract: "Delete a downloaded model")
    @OptionGroup var arg: ModelArg
    func run() async throws {
        let api = SpaceAPI()
        do { _ = try await api.raw("DELETE", "ollama/models", query: ["name": arg.model]) }
        catch let SpaceAPI.Failure.server(m) { throw ValidationError(m) }
        print("deleted \(arg.model)")
    }
}

struct OllamaSettingsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "settings", abstract: "Show or change server settings (applied when Ollama restarts: `spaced restart ollama`)")
    @Option(help: "Models kept in memory at once (1-16)") var maxLoaded: Int?
    @Option(help: "Idle time before unloading: 5m, 1h, -1 for forever") var keepAlive: String?
    @Option(help: "Simultaneous requests per model (1-16)") var parallel: Int?
    func run() async throws {
        let daemon = Daemon()
        var s: OllamaSettings = try await daemon.get("ollama/settings")
        if maxLoaded != nil || keepAlive != nil || parallel != nil {
            if let maxLoaded { s.maxLoadedModels = maxLoaded }
            if let keepAlive { s.keepAlive = keepAlive }
            if let parallel { s.numParallel = parallel }
            s = try await daemon.post("ollama/settings", body: s)
            print("saved — run `spaced restart ollama` to apply")
        }
        print("max loaded models: \(s.maxLoadedModels.map(String.init) ?? "default")")
        print("keep alive:        \(s.keepAlive ?? "default (5m)")")
        print("parallel requests: \(s.numParallel.map(String.init) ?? "default")")
    }
}
