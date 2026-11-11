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
    let api = SpaceAPI()
    let launcher = DaemonLauncher()

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

    private var loop: Task<Void, Never>?
    private var lastPeerRefresh = Date.distantPast

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            await self?.ensureDaemon()
            while !Task.isCancelled {
                await self?.refresh()
                let fast = (self?.visibleSurfaces ?? 0) > 0
                try? await Task.sleep(for: .seconds(fast ? 2 : 10))
            }
        }
    }

    // MARK: Refresh

    func refresh() async {
        do {
            async let s: [ServiceView] = api.get("services")
            async let st: [ServiceStats] = api.get("stats")
            async let n: TailnetStatus = api.get("net")
            async let m: [MountView] = api.get("mounts")
            async let h: HostsStatus = api.get("hosts")
            let (svc, stat, net, mnt, hst) = try await (s, st, n, m, h)
            hosts = hst
            services = svc
            for s in svc where resourceTitles[s.id] == nil {
                if let r: RecipeView = try? await api.get("services/\(s.id)/recipe") {
                    resourceTitles[s.id] = (r.recipe.resources ?? []).map(\.title)
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
        guard let list: [TailnetStatus.Device] = try? await api.get("net/peers") else { return }
        peers = list
        for p in list where p.online {
            peerServices[p.name] = try? await api.get("net/peers/\(p.name)/services")
        }
    }

    // MARK: Daemon

    func ensureDaemon() async {
        if await api.isUp() { daemonUp = true; return }
        do {
            try await launcher.start()
            if !(await waitForDaemon()) {
                try await launcher.retry()
                _ = await waitForDaemon()
            }
            daemonUp = await api.isUp()
        } catch {
            daemonUp = false
            lastError = error.localizedDescription
        }
    }

    private func waitForDaemon(seconds: Int = 8) async -> Bool {
        for _ in 0..<(seconds * 4) {
            if await api.isUp() { return true }
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

    func setRunning(_ s: ServiceView, _ on: Bool, origin: String = "popover") {
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
        perform("\(peer)/\(service)") { [api] in
            if on { _ = try await api.post("mounts", body: MountRequest(peer: peer, service: service), as: MountView.self) }
            else { _ = try await api.delete("mounts/\(peer)/\(service)", as: OK.self) }
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

    // MARK: Local hostnames

    func addSite(name: String, port: Int) {
        perform("site:\(name)") { [api] in _ = try await api.post("hosts/sites", body: SiteRequest(name: name, port: port), as: HostsStatus.self) }
    }

    func removeSite(_ name: String) {
        perform("site:\(name)") { [api] in _ = try await api.delete("hosts/sites/\(name)", as: HostsStatus.self) }
    }

    // MARK: Tailnet

    func login(open: OpenURLAction) {
        loggingIn = true
        Task {
            defer { loggingIn = false }
            do {
                var s: TailnetStatus = try await api.post("net/login")
                if let url = s.authURL.flatMap(URL.init(string:)), !s.loggedIn { open(url) }
                for _ in 0..<300 where !s.loggedIn {
                    try await Task.sleep(for: .seconds(1))
                    s = try await api.get("net")
                }
                tailnet = s
                await refreshPeers()
            } catch { lastError = error.localizedDescription }
        }
    }

    func logout() {
        perform("tailnet") { [api] in try await api.post("net/logout", as: OK.self) }
    }

    // MARK: Helpers

    func manageTitles(_ id: String) -> String {
        (resourceTitles[id] ?? []).joined(separator: ", ").lowercased().capitalizedFirst
    }

    var runningCount: Int { services.filter(\.isRunning).count }
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
    static func percent(_ v: Double) -> String { String(format: v < 10 ? "%.1f%%" : "%.0f%%", v) }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
