import Foundation
import Testing
@testable import SpaceCore

@Suite struct OllamaTests {
    @Test func recipeRunsNatively() throws {
        let r = try #require(try RecipeStore(userDirectory: nil)["ollama"])
        #expect(r.native?.executables.contains("/opt/homebrew/bin/ollama") == true)
        #expect(r.native?.args == ["serve"])
        #expect(r.hostPort("api") == 11434)
        #expect(r.connectionInfo["openai"] == "http://localhost:11434/v1")
        #expect(r.expand(r.health!.exec[0]) == "http://127.0.0.1:11434/api/version")
        #expect(r.projectEnv?["OLLAMA_HOST"] == "http://localhost:{port.api}")
    }

    @Test func containerRecipesAreNotNative() throws {
        let store = try RecipeStore(userDirectory: nil)
        #expect(store.all.filter { $0.native != nil }.map(\.id) == ["ollama"])
    }

    @Test func modelNamesGetATag() throws {
        #expect(try ServiceManager.canonicalModelName("llama3.2") == "llama3.2:latest")
        #expect(try ServiceManager.canonicalModelName(" qwen2.5:7b ") == "qwen2.5:7b")
        #expect(try ServiceManager.canonicalModelName("hf.co/bartowski/Llama-3.2-3B-GGUF:Q4_K_M") == "hf.co/bartowski/Llama-3.2-3B-GGUF:Q4_K_M")
        #expect(try ServiceManager.canonicalModelName("hf.co/org/model") == "hf.co/org/model:latest")
    }

    @Test func badModelNamesAreRejected() {
        for bad in ["", "  ", "-rf", "a b", "x;y", "../etc", String(repeating: "a", count: 201)] {
            #expect(throws: ActionError.self) { try ServiceManager.canonicalModelName(bad) }
        }
    }

    @Test func parsesOllamaTimestamps() throws {
        // Ollama prints nanoseconds and a local offset.
        let d = try #require(OllamaClient.parseDate("2024-06-04T14:38:31.837531234-07:00"))
        #expect(d.timeIntervalSince1970 == 1_717_537_111.837 || abs(d.timeIntervalSince1970 - 1_717_537_111.837) < 0.01)
        #expect(OllamaClient.parseDate("2024-06-04T14:38:31Z") != nil)
        #expect(OllamaClient.parseDate("garbage") == nil)
    }

    @Test func keepAliveForeverCountsAsPinned() {
        #expect(OllamaClient.isPinned(expires: Date().addingTimeInterval(300)) == false)
        #expect(OllamaClient.isPinned(expires: Date().addingTimeInterval(86400 * 365 * 100)) == true)
        #expect(OllamaClient.isPinned(expires: OllamaClient.parseDate("0001-01-01T00:00:00Z")) == true)
        #expect(OllamaClient.isPinned(expires: nil) == false)
    }

    @Test func settingsBecomeEnvironment() throws {
        let s = try OllamaSettings(maxLoadedModels: 2, keepAlive: " 30m ", numParallel: 4).validated()
        #expect(s.environment == ["OLLAMA_MAX_LOADED_MODELS": "2", "OLLAMA_KEEP_ALIVE": "30m", "OLLAMA_NUM_PARALLEL": "4"])
        #expect(try OllamaSettings(keepAlive: "-1").validated().environment == ["OLLAMA_KEEP_ALIVE": "-1"])
        #expect(try OllamaSettings(keepAlive: "  ").validated().keepAlive == nil)
        #expect(OllamaSettings().environment.isEmpty)
    }

    @Test func settingsRejectBadValues() {
        #expect(throws: ActionError.self) { try OllamaSettings(maxLoadedModels: 0).validated() }
        #expect(throws: ActionError.self) { try OllamaSettings(numParallel: 17).validated() }
        #expect(throws: ActionError.self) { try OllamaSettings(keepAlive: "soon").validated() }
        #expect(throws: ActionError.self) { try OllamaSettings(keepAlive: "5 minutes").validated() }
    }

    @Test func pullProgressFraction() {
        let p = OllamaPull(name: "a:latest", status: "pulling", completedBytes: 50, totalBytes: 200, done: false, error: nil)
        #expect(p.fraction == 0.25)
        #expect(OllamaPull(name: "a", status: "starting", completedBytes: 0, totalBytes: 0, done: false, error: nil).fraction == nil)
    }
}

@Suite struct NativeInstallTests {
    /// Builds <tmp>/<files> and returns the root, for classifying real symlinks.
    func tree(_ build: (URL) throws -> Void) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "space-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try build(root)
        return root
    }

    func file(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data())
    }

    @Test func homebrewInstallIsDetectedThroughTheSymlink() throws {
        let root = try tree { r in
            try file(r.appending(path: "Cellar/ollama/0.9.0/bin/ollama"))
            try FileManager.default.createDirectory(at: r.appending(path: "bin"), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: r.appending(path: "bin/ollama"), withDestinationURL: r.appending(path: "Cellar/ollama/0.9.0/bin/ollama"))
        }
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(NativeInstall.classify(root.appending(path: "bin/ollama").path) == .brew)
    }

    @Test func appInstallIsDetectedThroughTheSymlink() throws {
        // What the Ollama app sets up: /usr/local/bin/ollama → Ollama.app/Contents/Resources/ollama.
        let root = try tree { r in
            try file(r.appending(path: "Ollama.app/Contents/Resources/ollama"))
            try FileManager.default.createDirectory(at: r.appending(path: "bin"), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: r.appending(path: "bin/ollama"), withDestinationURL: r.appending(path: "Ollama.app/Contents/Resources/ollama"))
        }
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(NativeInstall.classify(root.appending(path: "bin/ollama").path) == .app)
    }

    @Test func otherAndMissingInstalls() throws {
        let root = try tree { try file($0.appending(path: "bin/ollama")) }
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(NativeInstall.classify(root.appending(path: "bin/ollama").path) == .other)
        #expect(NativeInstall.classify(nil) == .none)
    }

    @Test func whatSpaceCanDoDependsOnHowItWasInstalled() {
        func info(_ source: NativeInstall.Source, brew: Bool) -> NativeInstall {
            NativeInstall(source: source, path: nil, brewAvailable: brew, formula: "ollama", downloadURL: nil, installing: false, error: nil)
        }
        #expect(info(.none, brew: true).canInstall)
        #expect(!info(.none, brew: false).canInstall)
        #expect(info(.brew, brew: true).canUpdate)
        #expect(!info(.app, brew: true).canUpdate)
        #expect(!info(.other, brew: true).canUpdate)
        #expect(!info(.brew, brew: true).canInstall)
    }

    @Test func ollamaRecipeKnowsItsFormula() throws {
        let n = try #require(try RecipeStore(userDirectory: nil)["ollama"]?.native)
        #expect(n.brew == "ollama")
        #expect(n.download == "https://ollama.com/download")
    }
}
