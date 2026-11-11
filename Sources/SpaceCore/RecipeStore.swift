import Foundation
import Yams

/// Loads built-in recipes, then lets files in ~/.config/space/recipes override them by `id`.
public struct RecipeStore: Sendable {
    public private(set) var recipes: [String: Recipe] = [:]
    /// Where each recipe was loaded from (last one wins).
    public private(set) var sources: [String: URL] = [:]
    let userDirectory: URL?

    public init(userDirectory: URL? = SpacePaths.recipes) throws {
        self.userDirectory = userDirectory
        try load(from: Self.builtinDirectory)
        if let userDirectory, FileManager.default.fileExists(atPath: userDirectory.path) {
            try load(from: userDirectory)
        }
    }

    /// Built-in recipes: inside Space.app's Resources when bundled, else SwiftPM's resource bundle.
    /// (Checked in that order because touching `Bundle.module` traps when its bundle is missing.)
    static var builtinDirectory: URL {
        if let r = Bundle.main.resourceURL?.appending(path: "Recipes"),
           FileManager.default.fileExists(atPath: r.appending(path: "postgres.yaml").path) {
            return r
        }
        return Bundle.module.url(forResource: "Recipes", withExtension: nil)!
    }

    public func overrideURL(_ id: String) -> URL? { userDirectory?.appending(path: "\(id).yaml") }

    /// Override file path if the recipe currently comes from the user's directory.
    public func overridePath(_ id: String) -> String? {
        guard let src = sources[id], let dir = userDirectory,
              src.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL else { return nil }
        return src.path
    }

    /// Copies the active YAML for `id` into the user directory (if not already there) and returns its path.
    public func makeOverride(_ id: String) throws -> URL {
        guard let src = sources[id], let dest = overrideURL(id) else { throw ServiceError.unknownService(id) }
        if overridePath(id) == nil {
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: src, to: dest)
        }
        return dest
    }

    /// Logo file for a recipe: next to its YAML, else in the built-in folder.
    public func logoURL(_ id: String) -> URL? {
        guard let name = recipes[id]?.logo, !name.contains("/") else { return nil }
        let candidates = [sources[id]?.deletingLastPathComponent(), Self.builtinDirectory].compactMap { $0?.appending(path: name) }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    public func yaml(_ id: String) -> String {
        sources[id].flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }

    public var all: [Recipe] { recipes.values.sorted { $0.name < $1.name } }

    public subscript(id: String) -> Recipe? { recipes[id] }

    mutating func load(from dir: URL) throws {
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { ["yaml", "yml"].contains($0.pathExtension) }
        for file in files {
            let recipe = try Self.decode(try String(contentsOf: file, encoding: .utf8), source: file.lastPathComponent)
            recipes[recipe.id] = recipe
            sources[recipe.id] = file
        }
    }

    public static func decode(_ yaml: String, source: String = "<string>") throws -> Recipe {
        do {
            return try YAMLDecoder().decode(Recipe.self, from: yaml)
        } catch {
            throw RecipeLoadError(source: source, underlying: error)
        }
    }
}

public struct RecipeLoadError: Error, CustomStringConvertible {
    public let source: String
    public let underlying: any Error
    public var description: String { "Failed to load recipe \(source): \(underlying)" }
}
