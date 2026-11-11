import Foundation

/// Runs a shell script with administrator privileges via the standard macOS password dialog.
public enum AdminRunner {
    public static func run(_ script: String, prompt: String = "Space needs your password to finish setting up local hostnames.") async throws -> CommandResult {
        func quote(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let apple = "do shell script \(quote(script)) with prompt \(quote(prompt)) with administrator privileges"
        return try await ProcessRunner.run("/usr/bin/osascript", ["-e", apple])
    }
}

public enum CertificateTrust {
    /// Trusts a root certificate for this user. macOS shows its own authorization prompt.
    public static func trust(_ path: String) async throws -> CommandResult {
        let keychain = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Keychains/login.keychain-db").path
        return try await ProcessRunner.run("/usr/bin/security", ["add-trusted-cert", "-r", "trustRoot", "-k", keychain, path])
    }
}
