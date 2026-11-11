import Foundation

public enum SpacePaths {
    public static var root: URL {
        if let custom = ProcessInfo.processInfo.environment["SPACE_HOME"] {
            return URL(fileURLWithPath: custom)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/space")
    }

    public static var recipes: URL { root.appending(path: "recipes") }

    public static func ensure() throws {
        try FileManager.default.createDirectory(at: recipes, withIntermediateDirectories: true)
    }
}
