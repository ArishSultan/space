import Foundation
import ServiceManagement
import SpaceCore

/// Keeps `spaced` running. Inside Space.app it's a per-user LaunchAgent
/// (~/Library/LaunchAgents/dev.space.spaced.plist) loaded with launchctl, so it runs at login and
/// without the UI. A plain LaunchAgent is used instead of SMAppService because SMAppService pins the
/// agent to the exact code hash it first saw, which breaks every rebuild of an ad-hoc-signed app.
/// During development (`swift run Space`) the daemon is just a child process.
@MainActor
final class DaemonLauncher {
    static let label = "dev.space.spaced"
    private var child: Process?

    var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    private var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/LaunchAgents/\(Self.label).plist")
    }

    private var spacedURL: URL { Bundle.main.executableURL!.deletingLastPathComponent().appending(path: "spaced") }

    private var domain: String { "gui/\(getuid())" }

    /// True the first time a different build of the app runs than last time (an update was installed). The daemon
    /// that is still running then belongs to the old build and must be restarted. Containers keep running.
    func appWasUpdated() -> Bool {
        let info = Bundle.main.infoDictionary
        let current = "\(info?["CFBundleShortVersionString"] ?? "")+\(info?["CFBundleVersion"] ?? "")"
        let key = "lastLaunchedBuild"
        let previous = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.set(current, forKey: key)
        return isBundled && previous != nil && previous != current
    }

    func start() async throws {
        guard isBundled else { return try startChild() }

        // Migrate away from an earlier SMAppService registration with the same label.
        let legacy = SMAppService.agent(plistName: "\(Self.label).plist")
        if legacy.status != .notRegistered { try? await legacy.unregister() }

        try writePlist()
        _ = try? await launchctl(["bootout", "\(domain)/\(Self.label)"])
        let r = try await launchctl(["bootstrap", domain, plistURL.path])
        guard r.ok else { throw LauncherError.launchctl(r.stderr.isEmpty ? r.stdout : r.stderr) }
    }

    /// Second attempt when the daemon didn't come up: restart the job in place.
    func retry() async throws {
        guard isBundled else { return }
        _ = try await launchctl(["kickstart", "-k", "\(domain)/\(Self.label)"])
    }

    private func writePlist() throws {
        let plist: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": [spacedURL.path, "serve"],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Background",
            "StandardOutPath": "/tmp/\(Self.label).log",
            "StandardErrorPath": "/tmp/\(Self.label).log",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? Data(contentsOf: plistURL)) != data { try data.write(to: plistURL, options: .atomic) }
    }

    private func launchctl(_ args: [String]) async throws -> CommandResult {
        try await ProcessRunner.run("/bin/launchctl", args)
    }

    private func startChild() throws {
        let p = Process()
        p.executableURL = spacedURL
        p.arguments = ["serve"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        child = p
    }

    /// Whether the app itself opens at login.
    var opensAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            if newValue { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
        }
    }
}

enum LauncherError: LocalizedError {
    case launchctl(String)
    var errorDescription: String? {
        switch self { case .launchctl(let m): "Couldn't start Space's background service: \(m)" }
    }
}
