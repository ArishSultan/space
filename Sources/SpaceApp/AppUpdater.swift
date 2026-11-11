import AppKit
import Observation
import Sparkle

/// Auto-update through Sparkle. Releases are zips on GitHub; the appcast (`appcast.xml`) is a release asset and every
/// update is EdDSA-signed. Only active inside the packaged app (a development `swift run` has no update feed).
@MainActor @Observable
final class AppUpdater: NSObject, SPUStandardUserDriverDelegate {
    private var controller: SPUStandardUpdaterController?

    private(set) var canCheck = false
    var isAvailable: Bool { controller != nil }

    var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    /// Download and install in the background; the new version starts the next time Space is opened.
    var automaticallyInstalls: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set { controller?.updater.automaticallyDownloadsUpdates = newValue }
    }

    var lastChecked: Date? { controller?.updater.lastUpdateCheckDate }

    override init() {
        super.init()
        guard Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
        canCheck = true
    }

    func checkForUpdates() { controller?.checkForUpdates(nil) }

    // MARK: SPUStandardUserDriverDelegate

    /// Space has no Dock icon, so a scheduled update prompt would otherwise appear behind other windows.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                               state: SPUUserUpdateState) {
        Task { @MainActor in NSApplication.shared.activate() }
    }
}
