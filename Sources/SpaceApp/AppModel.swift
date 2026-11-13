import AppKit
import Foundation
import Observation
import SpaceCore
import SwiftUI

struct StatSample: Identifiable, Hashable {
    let date: Date
    let cpu: Double
    let memory: Double
    var id: Date { date }
}

/// App-wide state, refreshed from the local spaced API.
@MainActor @Observable
final class AppModel {
    /// This Mac's daemon (tailnet, hostnames, projects, mounts always live here).
    let local = SpaceAPI()
    let launcher = DaemonLauncher()

    /// Which Mac's services the panel shows: nil = this Mac, else a peer name (via the tailnet proxy).
    var host: String? {
        didSet {
            guard host != oldValue else { return }
            services = []; stats = [:]; history = [:]; resourceTitles = [:]
            Task { await refresh() }
        }
    }
    var api: SpaceAPI { host.map { SpaceAPI.remote(peer: $0) } ?? local }
    var isRemote: Bool { host != nil }

    /// Apps the user hid from the main panel (Settings → Apps), kept in UserDefaults.
    var hiddenInPanel: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "hiddenInPanel") ?? []) {
        didSet { UserDefaults.standard.set(Array(hiddenInPanel).sorted(), forKey: "hiddenInPanel") }
    }
    /// Services shown in the panel: not stack parts and not hidden by the user.
    var panelServices: [ServiceView] { services.filter { $0.hidden != true && !hiddenInPanel.contains($0.id) } }

    var projects: [ProjectView] = []
    var images: [ImageSetting] = []
    var disk: DiskUsage?
    var maintenanceBusy: String?
    var panelWindowOpen = false

    var daemonUp = true
    var services: [ServiceView] = []
    var stats: [String: ServiceStats] = [:]
    var history: [String: [StatSample]] = [:]
    var tailnet: TailnetStatus = .stopped
    var peers: [TailnetStatus.Device] = []
    var peerServices: [String: [RemoteService]] = [:]
    var mounts: [MountView] = []
    var hosts: HostsStatus?
    /// Service ids (or "peer/service") with an operation in flight.
    var busy: Set<String> = []
    var lastError: String?
    var loggingIn = false
    /// Resource section titles per service ("Projects, Databases, Users"), loaded once from recipes.
    var resourceTitles: [String: [String]] = [:]

    /// Faster polling while the popover or a window is on screen.
    var visibleSurfaces = 0

    static let historyLength = 90

    /// Network throughput across running services, in bytes per second (from successive stats samples).
    var networkRate: Double = 0
    private var lastNetwork: [String: (bytes: UInt64, at: Date)] = [:]

    /// Bytes Space's data volumes use on disk (loaded with the maintenance info).
    var diskBytes: UInt64? { disk.map { $0.spaceVolumes.reduce(0) { $0 + $1.bytes } } }

    private var loop: Task<Void, Never>?
    private var lastPeerRefresh = Date.distantPast

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            await self?.ensureDaemon()
            while !Task.isCancelled {
                await self?.refresh()
                // The daemon went away (e.g. replaced by an update while shutting down): bring it back.
                if self?.daemonUp == false { await self?.ensureDaemon() }
                let fast = (self?.visibleSurfaces ?? 0) > 0
                try? await Task.sleep(for: .seconds(fast ? 2 : 10))
            }
        }
    }

    // MARK: Refresh

    func refresh() async {
        do {
            let api = self.api, local = self.local
            async let s: [ServiceView] = api.get("services")
            async let st: [ServiceStats] = api.get("stats")
            async let n: TailnetStatus = local.get("net")
            async let m: [MountView] = local.get("mounts")
            async let h: HostsStatus = local.get("hosts")
            async let p: [ProjectView] = local.get("projects")
            let (svc, stat, net, mnt, hst, prj) = try await (s, st, n, m, h, p)
            hosts = hst
            projects = prj
            services = svc
            for s in svc where resourceTitles[s.id] == nil {
                if let r: RecipeView = try? await api.get("services/\(s.id)/recipe") {
                    resourceTitles[s.id] = (r.recipe.resources ?? []).map(\.title) + (r.recipe.visibleActions.isEmpty ? [] : ["Actions"])
                }
            }
            tailnet = net
            mounts = mnt
            record(stat)
            daemonUp = true
            if net.loggedIn, Date().timeIntervalSince(lastPeerRefresh) > 10 { await refreshPeers() }
            if !net.loggedIn { peers = []; peerServices = [:] }
        } catch SpaceAPI.Failure.daemonNotRunning {
            daemonUp = false
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func record(_ list: [ServiceStats]) {
        stats = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
        var rate = 0.0
        var seen: [String: (bytes: UInt64, at: Date)] = [:]
        for s in list {
            let total = (s.networkRxBytes ?? 0) + (s.networkTxBytes ?? 0)
            if let prev = lastNetwork[s.id], s.sampledAt > prev.at, total >= prev.bytes {
                rate += Double(total - prev.bytes) / s.sampledAt.timeIntervalSince(prev.at)
            }
            seen[s.id] = (total, s.sampledAt)
        }
        lastNetwork = seen
        networkRate = rate
        let now = Date()
        for s in list {
            var h = history[s.id, default: []]
            h.append(StatSample(date: now, cpu: s.cpuPercent ?? 0, memory: Double(s.memoryBytes ?? 0)))
            if h.count > Self.historyLength { h.removeFirst(h.count - Self.historyLength) }
            history[s.id] = h
        }
        for id in history.keys where stats[id] == nil { history[id] = nil }
    }

    func refreshPeers() async {
        lastPeerRefresh = Date()
        guard let list: [TailnetStatus.Device] = try? await local.get("net/peers") else { return }
        peers = list
        for p in list where p.online {
            peerServices[p.name] = try? await local.get("net/peers/\(p.name)/services")
        }
    }

    // MARK: Daemon

    func ensureDaemon() async {
        if launcher.appWasUpdated() {
            // A new build was installed: replace the daemon that is still running the old one.
            try? await launcher.start()
            _ = await waitForDaemon()
        }
        if await local.isUp() { daemonUp = true; return }
        do {
            try await launcher.start()
            if !(await waitForDaemon()) {
                try await launcher.retry()
                _ = await waitForDaemon()
            }
            daemonUp = await local.isUp()
        } catch {
            daemonUp = false
            lastError = error.localizedDescription
        }
    }

    private func waitForDaemon(seconds: Int = 8) async -> Bool {
        for _ in 0..<(seconds * 4) {
            if await local.isUp() { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

    // MARK: Service operations

    /// An interrupting operation waiting for the user to confirm because clients are connected.
    struct Confirmation: Identifiable {
        let id = UUID()
        /// Where to show the dialog: "popover" or a service id (its window).
        let origin: String
        let serviceName: String
        let verb: String
        let clients: ClientsInfo
        let proceed: () -> Void
    }

    var confirmation: Confirmation?

    /// A confirmation drawn inside the menu-bar panel. System alerts can't be used there: they open their own
    /// window, the panel loses focus and closes, and the buttons never receive the click.
    struct PanelAlert {
        let title: String
        let message: String
        let confirm: String
        var destructive = true
        let action: () -> Void
    }

    var panelAlert: PanelAlert?

    /// Runs `action` right away unless the service has connected clients, in which case it asks first.
    func confirmIfConnected(_ id: String, verb: String, origin: String, _ action: @escaping () -> Void) {
        guard let s = services.first(where: { $0.id == id }), s.isRunning else { action(); return }
        busy.insert(id)
        Task {
            let info: ClientsInfo? = try? await api.get("services/\(id)/clients")
            busy.remove(id)
            if let info, info.count > 0 {
                confirmation = Confirmation(origin: origin, serviceName: s.name, verb: verb, clients: info, proceed: action)
            } else {
                action()
            }
        }
    }

    /// Installs a native service (Ollama) with Homebrew; it runs in the background and shows up in the service list.
    func install(_ s: ServiceView) {
        perform(s.id) { [api] in try await api.post("services/\(s.id)/install", as: NativeInstall.self) }
    }

    func setRunning(_ s: ServiceView, _ on: Bool, origin: String = "popover") {
        if on, let install = s.install, !install.installed { return self.install(s) }
        let op = { [self] in perform(s.id) { [api] in try await api.post("services/\(s.id)/\(on ? "start" : "stop")", as: OK.self) } }
        if on { op() } else { confirmIfConnected(s.id, verb: "Stop", origin: origin, op) }
    }

    func restart(_ id: String, origin: String = "popover") {
        confirmIfConnected(id, verb: "Restart", origin: origin) { [self] in
            perform(id) { [api] in try await api.post("services/\(id)/restart", as: OK.self) }
        }
    }

    func pullLatest(_ id: String, origin: String = "popover") {
        confirmIfConnected(id, verb: "Update", origin: origin) { [self] in
            perform(id) { [api] in try await api.post("services/\(id)/pull", as: OK.self) }
        }
    }

    func setShared(_ s: ServiceView, _ on: Bool) {
        perform(s.id) { [api] in try await api.post("services/\(s.id)/\(on ? "share" : "unshare")", as: OK.self) }
    }

    func mount(_ peer: String, _ service: String, _ on: Bool) {
        perform("\(peer)/\(service)") { [local] in
            if on { _ = try await local.post("mounts", body: MountRequest(peer: peer, service: service), as: MountView.self) }
            else { _ = try await local.delete("mounts/\(peer)/\(service)", as: OK.self) }
        }
    }

    func mountFor(_ peer: String, _ service: String) -> MountView? {
        mounts.first { $0.peer == peer && $0.service == service }
    }

    /// Runs an API operation for `key`, marking it busy and refreshing afterwards.
    func perform(_ key: String, _ op: @escaping @Sendable () async throws -> Void) {
        busy.insert(key)
        Task {
            defer { busy.remove(key) }
            do { try await op() } catch { lastError = error.localizedDescription }
            await refresh()
        }
    }

    // MARK: Tailnet

    func login(open: OpenURLAction) {
        loggingIn = true
        Task {
            defer { loggingIn = false }
            do {
                var s: TailnetStatus = try await local.post("net/login")
                if let url = s.authURL.flatMap(URL.init(string:)), !s.loggedIn { open(url) }
                for _ in 0..<300 where !s.loggedIn {
                    try await Task.sleep(for: .seconds(1))
                    s = try await local.get("net")
                }
                tailnet = s
                await refreshPeers()
            } catch { lastError = error.localizedDescription }
        }
    }

    func logout() {
        perform("tailnet") { [local] in try await local.post("net/logout", as: OK.self) }
    }

    // MARK: Projects

    func createProject(name: String) async -> ProjectView? {
        busy.insert("project")
        defer { busy.remove("project") }
        do {
            let p: ProjectView = try await local.post("projects", body: ProjectRequest(name: name))
            await refresh()
            return p
        } catch { lastError = error.localizedDescription; return nil }
    }

    func addEndpoint(project: String, name: String, port: Int, hostname: String?) {
        perform("project:\(project)") { [local] in
            _ = try await local.post("projects/\(project)/endpoints", body: EndpointRequest(name: name, port: port, hostname: hostname), as: ProjectView.self)
        }
    }

    func removeEndpoint(project: String, name: String) {
        perform("project:\(project)") { [local] in _ = try await local.raw("DELETE", "projects/\(project)/endpoints/\(name)") }
    }

    func deleteProject(_ name: String) {
        perform("project:\(name)") { [local] in _ = try await local.raw("DELETE", "projects/\(name)") }
    }

    /// Projects that link to this resource (shown beside it in a service's Manage tab).
    func projectsUsing(service: String, kind: String, name: String) -> [String] {
        projects.filter { $0.resources.contains { $0.service == service && $0.kind == kind && $0.name == name } }.map(\.name)
    }

    // MARK: Apps & storage (Settings)

    func loadMaintenance() async {
        images = (try? await api.get("images")) ?? []
        disk = try? await api.get("system/disk")
    }

    func setImage(_ id: String, _ image: String?) {
        perform("image:\(id)") { [api] in _ = try await api.post("images/\(id)", body: ImageOverrideRequest(image: image), as: [ImageSetting].self) }
        Task { try? await Task.sleep(for: .milliseconds(300)); await loadMaintenance() }
    }

    func updateAll() {
        maintenanceBusy = "Updating all apps…"
        Task {
            defer { maintenanceBusy = nil }
            do {
                let r: UpdateResult = try await api.post("system/update-all")
                if !r.failed.isEmpty { lastError = r.failed.map { "\($0.key): \($0.value)" }.joined(separator: "\n") }
            } catch { lastError = error.localizedDescription }
            await refresh(); await loadMaintenance()
        }
    }

    var lastReclaim: ReclaimResult?

    func reclaim(includeData: Bool) {
        maintenanceBusy = "Reclaiming space…"
        Task {
            defer { maintenanceBusy = nil }
            do { lastReclaim = try await api.post("system/reclaim", body: ReclaimRequest(includeData: includeData)) }
            catch { lastError = error.localizedDescription }
            await refresh(); await loadMaintenance()
        }
    }

    // MARK: Helpers

    func manageTitles(_ id: String) -> String {
        (resourceTitles[id] ?? []).joined(separator: ", ").lowercased().capitalizedFirst
    }

    var runningCount: Int { services.filter { $0.isRunning && $0.hidden != true }.count }
    var totalMemory: Double { stats.values.reduce(0) { $0 + Double($1.memoryBytes ?? 0) } }
    var totalCPU: Double { stats.values.reduce(0) { $0 + ($1.cpuPercent ?? 0) } }

    /// SwiftUI has no clipboard-write API on macOS, so this is the one AppKit call we keep.
    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

enum Format {
    static func bytes(_ v: Double) -> String {
        switch v {
        case ..<1: "0"
        case ..<1_048_576.0: String(format: "%.0f KB", v / 1024)
        case ..<1_073_741_824.0: String(format: "%.0f MB", v / 1_048_576)
        default: String(format: "%.1f GB", v / 1_073_741_824)
        }
    }
    static func rate(_ bytesPerSecond: Double) -> String {
        switch bytesPerSecond {
        case ..<1: "0 KB/s"
        case ..<1_048_576.0: String(format: "%.0f KB/s", bytesPerSecond / 1024)
        default: String(format: "%.1f MB/s", bytesPerSecond / 1_048_576)
        }
    }
    static func percent(_ v: Double) -> String { String(format: v < 10 ? "%.1f%%" : "%.0f%%", v) }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
