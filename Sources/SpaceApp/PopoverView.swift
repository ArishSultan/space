import Charts
import SpaceCore
import SwiftUI

struct PopoverView: View {
    @Environment(AppModel.self) private var model
    @State private var showUsage = false
    @State private var contentHeight: CGFloat = 300
    @State private var moreBelow = false

    /// Tallest the scrolling part may get before it scrolls (header stays fixed above it).
    static let maxContentHeight: CGFloat = 600

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if !model.daemonUp {
                        DaemonDownCard()
                    } else {
                        VStack(spacing: 2) {
                            ForEach(model.panelServices) { ServiceTile(service: $0) }
                        }

                        if !model.isRemote {
                            ProjectsSection()
                            SitesSection()
                        }

                        if model.runningCount > 0 {
                            UsagePanel(expanded: $showUsage)
                        }

                        if model.tailnet.loggedIn, !model.peers.isEmpty, !model.isRemote {
                            PeersSection()
                        }
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            // Hug the content, but never taller than the max — beyond that it scrolls with a visible bar.
            .frame(height: min(max(contentHeight, 1), Self.maxContentHeight))
            .scrollIndicators(contentHeight > Self.maxContentHeight ? .visible : .hidden)
            .scrollIndicatorsFlash(onAppear: true)
            .scrollBounceBehavior(.basedOnSize)
            .onScrollGeometryChange(for: Bool.self) { g in
                g.contentOffset.y + g.containerSize.height < g.contentSize.height - 4
            } action: { _, more in moreBelow = more }
            .overlay(alignment: .bottom) {
                // Soft fade hinting there's more to scroll to.
                if moreBelow {
                    Rectangle().fill(.background)
                        .mask(LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom))
                        .frame(height: 28)
                        .allowsHitTesting(false)
                }
            }

            if let error = model.lastError {
                ErrorBanner(message: error) { model.lastError = nil }
            }
        }
        .padding(12)
        .frame(width: 360)
        .background { QuitShortcuts() }
        .connectedClientsAlert(origin: "popover")
        .onAppear { model.visibleSurfaces += 1; Task { await model.refresh() } }
        .onDisappear { model.visibleSurfaces -= 1 }
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Space").font(.headline)
                if model.peers.contains(where: \.online) || model.isRemote {
                    HostPicker()
                } else {
                    Text(model.daemonUp ? "\(model.runningCount) of \(model.panelServices.count) running" : "Service offline")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    TailnetButton()
                    SettingsButton()
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.large)
            }
        }
        .padding(.horizontal, 4)
    }
}

/// Switches the panel between this Mac and other Macs running Space.
struct HostPicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            Button { model.host = nil } label: {
                Label("This Mac", systemImage: model.host == nil ? "checkmark" : "laptopcomputer")
            }
            Divider()
            ForEach(model.peers.filter(\.online), id: \.name) { peer in
                Button { model.host = peer.name } label: {
                    Label(peer.name.replacingOccurrences(of: "space-", with: ""),
                          systemImage: model.host == peer.name ? "checkmark" : "desktopcomputer")
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(model.host.map { $0.replacingOccurrences(of: "space-", with: "") } ?? "This Mac")
                Text("· \(model.runningCount) running").foregroundStyle(.secondary)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .font(.caption)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Choose which Mac's services to control")
    }
}

/// Opens Settings and brings it to the front (a menu-bar app's windows otherwise stay behind).
struct SettingsButton: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button {
            NSApplication.shared.activate()
            openSettings()
        } label: {
            Image(systemName: "gearshape.fill")
        }
        .help("Settings")
    }
}

/// ⌘Q and ⌃Q quit the app without a visible button.
struct QuitShortcuts: View {
    var body: some View {
        ZStack {
            Button("Quit") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q", modifiers: .command)
            Button("Quit") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q", modifiers: .control)
        }
        .opacity(0)
        .accessibilityHidden(true)
    }
}

// MARK: - Service tile

struct ServiceTile: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openURL) private var openURL
    let service: ServiceView

    private var busy: Bool { model.busy.contains(service.id) }

    var body: some View {
        HStack(spacing: 10) {
            Button { openWindow.focused(id: "service", value: service.id) } label: {
                HStack(spacing: 10) {
                    ServiceIcon(service: service)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(service.name).font(.callout.weight(.semibold))
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .help("Details")

            Spacer(minLength: 6)

            if busy {
                ProgressView().controlSize(.small)
            }

            if model.tailnet.loggedIn, service.isRunning || service.shared {
                Button { model.setShared(service, !service.shared) } label: {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(service.shared ? Color.accentColor : .secondary)
                .help(service.shared ? "Shared with your other Macs" : "Share with your other Macs")
                .disabled(busy)
            }

            GlassEffectContainer(spacing: 4) {
                HStack(spacing: 4) {
                    Button { openWindow.focused(id: "logs", value: service.id) } label: {
                        Image(systemName: "text.alignleft").glassCircle()
                    }
                    .buttonStyle(.plain)
                    .help("Logs")
                    .disabled(service.state == "not_created")

                    Menu { menu } label: { Image(systemName: "ellipsis").glassCircle() }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .menuIndicator(.hidden)
                        .help("More")
                }
            }

            Toggle("", isOn: Binding(get: { service.isRunning }, set: { model.setRunning(service, $0) }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .disabled(busy)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var subtitle: String {
        if busy { return service.isRunning ? "Working…" : "Starting…" }
        switch service.state {
        case "running":
            if service.healthy == false { return "Starting up…" }
            return service.ports.values.sorted().map { "localhost:\($0)" }.joined(separator: " · ")
        case "not_created": return "Not installed · turn on to download"
        default: return "Stopped"
        }
    }

    @ViewBuilder private var menu: some View {
        Button("Details…", systemImage: "info.circle") { openWindow.focused(id: "service", value: service.id) }
        if !model.manageTitles(service.id).isEmpty {
            Button("Manage \(model.manageTitles(service.id))…", systemImage: "square.stack.3d.up") {
                openWindow.focused(id: "service", value: "\(service.id)/Manage")
            }
            .disabled(!service.isRunning)
        }
        if !service.connection.isEmpty {
            Divider()
            ForEach(service.connection.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                Button("Copy \(key) — \(value)", systemImage: "doc.on.doc") { model.copy(value) }
            }
        }
        if let admin = service.adminURL, let url = URL(string: admin) {
            Button("Open web UI", systemImage: "safari") { openURL(url) }
        }
        Divider()
        Button("Restart", systemImage: "arrow.clockwise") { model.restart(service.id) }.disabled(!service.isRunning)
        Button("Update to latest image", systemImage: "arrow.down.circle") { model.pullLatest(service.id) }
    }
}

// MARK: - Projects

struct ProjectsSection: View {
    @Environment(AppModel.self) private var model
    @State private var creating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("Projects", systemImage: "folder")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button { creating = true } label: { Image(systemName: "plus").glassCircle(size: 22) }
                    .buttonStyle(.plain)
                    .help("New project: ports, a .localhost hostname, and a database/bucket per service")
                    .popover(isPresented: $creating, arrowEdge: .trailing) { NewProjectForm { creating = false } }
            }
            .padding(.horizontal, 8)
            if model.projects.isEmpty {
                Text("A project bundles ports, a hostname and databases, with one .env to copy.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
            }
            ForEach(model.projects) { ProjectTile(project: $0) }
        }
    }
}

struct ProjectTile: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let project: ProjectView
    @State private var copied = false
    @State private var confirmDelete = false

    private var primaryHost: String? {
        project.ports.min { $0.value < $1.value }.flatMap { project.hosts[$0.key] }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .font(.system(size: 18))
                .foregroundStyle(.tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(project.name).font(.callout.weight(.semibold))
                Text(project.ports.sorted { $0.value < $1.value }.map { "\($0.key) :\(String($0.value))" }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            GlassEffectContainer(spacing: 4) {
                HStack(spacing: 4) {
                    Button {
                        model.copy(project.env)
                        copied = true
                        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.clipboard").glassCircle()
                    }
                    .buttonStyle(.plain)
                    .help("Copy .env")

                    Menu {
                        if let host = primaryHost, let url = URL(string: "http://\(host)") {
                            Button("Open http://\(host)", systemImage: "safari") { openURL(url) }
                        }
                        Button("Copy .env", systemImage: "doc.on.clipboard") { model.copy(project.env) }
                        Divider()
                        Button("Remove project (keep data)", systemImage: "minus.circle") { model.deleteProject(project.name, dropData: false) }
                        Button("Delete project and its data…", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    } label: { Image(systemName: "ellipsis").glassCircle() }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .menuIndicator(.hidden)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .alert("Delete \(project.name) and its data?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { model.deleteProject(project.name, dropData: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its databases, users and buckets in \(project.services.joined(separator: ", ")) are removed.")
        }
    }
}

struct NewProjectForm: View {
    @Environment(AppModel.self) private var model
    let done: () -> Void
    @State private var name = ""
    @State private var selected: Set<String> = ["postgres"]
    @State private var ports = "web"
    @State private var created: ProjectView?

    /// Services that contribute something to a project.
    private var choices: [ServiceView] {
        model.services.filter { $0.hidden != true }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let created {
                Label("\(created.name) is ready", systemImage: "checkmark.circle.fill").font(.headline).foregroundStyle(.green)
                ScrollView {
                    Text(created.env).font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 180)
                HStack {
                    Spacer()
                    Button("Copy .env") { model.copy(created.env); done() }.buttonStyle(.glassProminent)
                }
            } else {
                Text("New project").font(.headline)
                TextField("Name, e.g. acme", text: $name).textFieldStyle(.roundedBorder)
                Text("Services").font(.caption).foregroundStyle(.secondary)
                ForEach(choices) { s in
                    Toggle(isOn: Binding(get: { selected.contains(s.id) },
                                         set: { if $0 { selected.insert(s.id) } else { selected.remove(s.id) } })) {
                        HStack(spacing: 6) { ServiceIcon(service: s, size: 16); Text(s.name) }
                    }
                    .toggleStyle(.checkbox)
                }
                TextField("Ports (comma separated)", text: $ports).textFieldStyle(.roundedBorder)
                Text("The first port gets http://\(name.isEmpty ? "name" : name.lowercased()).localhost, others <port>.<name>.localhost.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    if model.busy.contains("project") { ProgressView().controlSize(.small); Text("Creating…").font(.caption) }
                    Spacer()
                    Button("Cancel", action: done)
                    Button("Create") {
                        Task {
                            created = await model.createProject(
                                name: name.lowercased(), services: choices.map(\.id).filter(selected.contains),
                                ports: ports.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
                        }
                    }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.count < 3 || model.busy.contains("project"))
                }
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}

// MARK: - Sites (local hostnames)

struct SitesSection: View {
    @Environment(AppModel.self) private var model
    @State private var adding = false

    var body: some View {
        if let hosts = model.hosts {
            let userSites = hosts.sites.filter { !$0.service }
            let serviceSites = hosts.sites.filter(\.service)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label("Sites", systemImage: "globe")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button { adding = true } label: { Image(systemName: "plus").glassCircle(size: 22) }
                        .buttonStyle(.plain)
                        .help("Add a hostname")
                        .popover(isPresented: $adding, arrowEdge: .trailing) {
                            AddSiteForm(suggestedPort: hosts.suggestedPort) { adding = false }
                        }
                }
                .padding(.horizontal, 8)

                if !hosts.routerRunning {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(hosts.routerError ?? "The *.\(hosts.domain) router isn't running")
                            .font(.caption)
                            .lineLimit(2)
                    }
                    .padding(.horizontal, 8)
                }

                if userSites.isEmpty {
                    Text("Give a local app a name like acme.\(hosts.domain).")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 8)
                }
                ForEach(userSites) { SiteTile(site: $0) }

                if !serviceSites.isEmpty {
                    Text("Services")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 8)
                        .padding(.top, 4)
                    ForEach(serviceSites) { SiteTile(site: $0) }
                }
            }
        }
    }
}

struct SiteTile: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let site: HostsStatus.SiteView

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: site.service ? "shippingbox" : "globe")
                .font(.system(size: 18))
                .foregroundStyle(site.up ? Color.accentColor : .secondary)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(site.host).font(.callout.weight(.semibold))
                Text(site.up ? "→ localhost:\(String(site.port))" : "→ localhost:\(String(site.port)) · nothing running")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            GlassEffectContainer(spacing: 4) {
                HStack(spacing: 4) {
                    Button { if let u = URL(string: site.url) { openURL(u) } } label: {
                        Image(systemName: "safari").glassCircle()
                    }
                    .buttonStyle(.plain)
                    .help("Open \(site.url)")

                    Menu {
                        Button("Copy \(site.url)", systemImage: "doc.on.doc") { model.copy(site.url) }
                        if !site.service {
                            Divider()
                            Button("Remove", systemImage: "trash", role: .destructive) { model.removeSite(site.name) }
                        }
                    } label: { Image(systemName: "ellipsis").glassCircle() }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .menuIndicator(.hidden)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }
}

struct AddSiteForm: View {
    @Environment(AppModel.self) private var model
    let suggestedPort: Int
    let done: () -> Void
    @State private var name = ""
    @State private var port = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New hostname").font(.headline)
            HStack(spacing: 4) {
                Text("http://").foregroundStyle(.secondary)
                TextField("acme", text: $name).textFieldStyle(.roundedBorder).frame(width: 110)
                Text(".\(model.hosts?.domain ?? "localhost")").foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                Text("→ localhost:").foregroundStyle(.secondary)
                TextField(String(suggestedPort), text: $port).textFieldStyle(.roundedBorder).frame(width: 70)
            }
            HStack {
                Spacer()
                Button("Cancel", action: done)
                Button("Add") {
                    model.addSite(name: name.lowercased(), port: Int(port) ?? suggestedPort)
                    done()
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty)
            }
        }
        .padding(14)
        .frame(width: 280)
    }
}

// MARK: - Usage

struct UsagePanel: View {
    @Environment(AppModel.self) private var model
    @Binding var expanded: Bool
    @State private var metric = Metric.memory

    enum Metric: String, CaseIterable { case memory = "Memory", cpu = "CPU" }

    private struct Point: Identifiable {
        let service: String
        let date: Date
        let value: Double
        var id: String { "\(service)-\(date.timeIntervalSince1970)" }
    }

    private var running: [ServiceView] { model.services.filter(\.isRunning) }

    private var points: [Point] {
        running.flatMap { s in
            (model.history[s.id] ?? []).map { Point(service: s.name, date: $0.date, value: metric == .memory ? $0.memory : $0.cpu) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                HStack {
                    Image(systemName: "chart.bar.xaxis").foregroundStyle(.tint)
                    Text("Usage").font(.callout.weight(.semibold))
                    Spacer()
                    Text("\(Format.percent(model.totalCPU)) CPU · \(Format.bytes(model.totalMemory))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if expanded {
                Picker("", selection: $metric) {
                    ForEach(Metric.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Chart(points) {
                    AreaMark(x: .value("Time", $0.date), y: .value(metric.rawValue, $0.value), stacking: .standard)
                        .foregroundStyle(by: .value("Service", $0.service))
                        .interpolationMethod(.monotone)
                }
                .chartForegroundStyleScale(domain: running.map(\.name), range: running.map(\.tint))
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { v in
                        AxisGridLine()
                        AxisValueLabel {
                            if let d = v.as(Double.self) { Text(metric == .memory ? Format.bytes(d) : Format.percent(d)) }
                        }
                    }
                }
                .chartXAxis(.hidden)
                .chartLegend(.hidden)
                .frame(height: 110)

                ForEach(running) { s in
                    if let st = model.stats[s.id] {
                        HStack(spacing: 6) {
                            Circle().fill(s.tint).frame(width: 7, height: 7)
                            Text(s.name)
                            Spacer()
                            Text(Format.percent(st.cpuPercent ?? 0)).monospacedDigit().frame(width: 52, alignment: .trailing)
                            Text(Format.bytes(Double(st.memoryBytes ?? 0))).monospacedDigit().frame(width: 64, alignment: .trailing)
                        }
                        .font(.caption)
                    }
                }
            }
        }
        .padding(12)
        .glassEffect(in: .rect(cornerRadius: 14))
    }
}

// MARK: - Tailnet & peers

struct TailnetButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    private var color: Color {
        if model.tailnet.loggedIn { return .green }
        if model.loggingIn || model.tailnet.state == "Starting" { return .orange }
        return .secondary
    }

    private var help: String {
        if model.tailnet.loggedIn {
            let online = model.peers.filter(\.online).count
            return "Tailscale: connected as \(model.tailnet.me?.name ?? "")" + (online > 0 ? " · \(online) other Mac\(online == 1 ? "" : "s") online" : "")
        }
        return model.loggingIn ? "Tailscale: waiting for browser login…" : "Tailscale: not connected"
    }

    var body: some View {
        Menu {
            if model.tailnet.loggedIn {
                Text("This Mac: \(model.tailnet.me?.name ?? "")")
                if let t = model.tailnet.tailnet { Text("Tailnet: \(t)") }
                Divider()
                Button("Log out of tailnet", role: .destructive) { model.logout() }
            } else {
                Button(model.loggingIn ? "Waiting for browser…" : "Connect with Tailscale…") { model.login(open: openURL) }
                    .disabled(model.loggingIn || !model.daemonUp)
            }
        } label: {
            TailnetMark.image(color: color, dot: 4.2)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .help(help)
    }
}

struct PeersSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Other Macs", systemImage: "desktopcomputer")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            ForEach(model.peers, id: \.name) { peer in
                let shared = (model.peerServices[peer.name] ?? []).filter(\.shared)
                HStack(spacing: 6) {
                    Circle().fill(peer.online ? .green : .secondary).frame(width: 6, height: 6)
                    Text(peer.name.replacingOccurrences(of: "space-", with: "")).font(.caption.weight(.medium))
                    if peer.online && shared.isEmpty { Text("· nothing shared").font(.caption).foregroundStyle(.tertiary) }
                }
                .padding(.horizontal, 8)
                ForEach(shared) { s in PeerServiceTile(peer: peer.name, service: s) }
            }
        }
    }
}

struct PeerServiceTile: View {
    @Environment(AppModel.self) private var model
    let peer: String
    let service: RemoteService

    var body: some View {
        let mount = model.mountFor(peer, service.id)
        HStack(spacing: 10) {
            ServiceIcon(service: service, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(service.name).font(.callout.weight(.medium))
                Text(mount.map { m in m.localPorts.values.sorted().map { "localhost:\($0)" }.joined(separator: " · ") }
                     ?? (service.isRunning ? "Available" : "Stopped on that Mac"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let mount, let first = mount.connection.sorted(by: { $0.key < $1.key }).first {
                Button { model.copy(first.value) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Copy \(first.key): \(first.value)")
            }
            Toggle("Use here", isOn: Binding(get: { mount != nil }, set: { model.mount(peer, service.id, $0) }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .disabled(model.busy.contains("\(peer)/\(service.id)"))
                .help("Make it available on this Mac's localhost")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }
}

// MARK: - Misc

struct DaemonDownCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Space's background service isn't running", systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(.orange)
            Text("It runs your containers and keeps them available even when this menu is closed.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Start service") { Task { await model.ensureDaemon(); await model.refresh() } }
                .buttonStyle(.glassProminent)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(.orange.opacity(0.12)), in: .rect(cornerRadius: 14))
    }
}

struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            Text(message).font(.caption).textSelection(.enabled).lineLimit(4)
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.borderless)
        }
        .padding(10)
        .glassEffect(.regular.tint(.red.opacity(0.15)), in: .rect(cornerRadius: 12))
    }
}

extension View {
    /// Small round Liquid Glass control used for the per-service buttons.
    func glassCircle(size: CGFloat = 26) -> some View {
        font(.system(size: 11, weight: .semibold))
            .frame(width: size, height: size)
            .contentShape(.circle)
            .glassEffect(.regular.interactive(), in: .circle)
    }
}
