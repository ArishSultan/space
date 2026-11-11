import SpaceCore
import SwiftUI

struct PopoverView: View {
    @Environment(AppModel.self) private var model
    @State private var contentHeight: CGFloat = 300
    @State private var moreBelow = false

    /// Tallest the scrolling part may get before it scrolls (header stays fixed above it).
    static let maxContentHeight: CGFloat = 640

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !model.daemonUp {
                        DaemonDownCard()
                    } else {
                        ServicesSection()
                        if !model.isRemote { ProjectsSection() }
                        UsagePanel()
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
        .padding(16)
        .frame(width: 420)
        .background { QuitShortcuts() }
        .connectedClientsAlert(origin: "popover")
        .onAppear { model.visibleSurfaces += 1; Task { await model.refresh(); await model.loadMaintenance() } }
        .onDisappear { model.visibleSurfaces -= 1 }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Space").font(.title3.weight(.semibold))
                Text(model.daemonUp ? "\(model.runningCount) of \(model.panelServices.count) running" : "Service offline")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            HStack(spacing: 14) {
                HostPicker()
                TailnetButton()
                SettingsButton()
            }
            .padding(.top, 2)
        }
    }
}

// MARK: - Shared pieces

/// Plain section title with an optional trailing control.
struct SectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            trailing
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: String) { self.init(title: title) { EmptyView() } }
}

/// Small status dot.
struct StatusDot: View {
    let color: Color
    var body: some View { Circle().fill(color).frame(width: 7, height: 7) }
}

/// Switches the panel between this Mac and other Macs running Space.
struct HostPicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            Button { model.host = nil } label: {
                Label("This Mac", systemImage: model.host == nil ? "checkmark" : "laptopcomputer")
            }
            let online = model.peers.filter(\.online)
            if !online.isEmpty { Divider() }
            ForEach(online, id: \.name) { peer in
                Button { model.host = peer.name } label: {
                    Label(peer.name.replacingOccurrences(of: "space-", with: ""),
                          systemImage: model.host == peer.name ? "checkmark" : "desktopcomputer")
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(model.host.map { $0.replacingOccurrences(of: "space-", with: "") } ?? "This Mac")
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold))
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.quaternary, in: .rect(cornerRadius: 8))
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
            Image(systemName: "gearshape").font(.system(size: 17))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
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

/// Round-less, plain `…` menu button used on every row.
struct MoreMenuLabel: View {
    var body: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 26, height: 26)
            .contentShape(.rect)
    }
}

// MARK: - Services

struct ServicesSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Services") {
                if model.maintenanceBusy != nil {
                    ProgressView().controlSize(.small)
                } else if !model.isRemote {
                    Button("Update All") { model.updateAll() }
                        .buttonStyle(.plain)
                        .font(.callout)
                        .foregroundStyle(.tint)
                        .help("Pull the latest image for every installed app (data is kept)")
                }
            }
            VStack(spacing: 6) {
                ForEach(model.panelServices) { ServiceTile(service: $0) }
            }
        }
    }
}

struct ServiceTile: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openURL) private var openURL
    let service: ServiceView

    private var busy: Bool { model.busy.contains(service.id) }

    var body: some View {
        HStack(spacing: 12) {
            Button { openWindow.focused(id: "service", value: service.id) } label: {
                HStack(spacing: 12) {
                    ServiceIcon(service: service, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(service.name).font(.body.weight(.medium))
                        HStack(spacing: 6) {
                            StatusDot(color: status.color)
                            Text(status.text).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .help("Details")

            if busy { ProgressView().controlSize(.small) }

            Menu { menu } label: { MoreMenuLabel() }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")

            Toggle("", isOn: Binding(get: { service.isRunning }, set: { model.setRunning(service, $0) }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .disabled(busy)
        }
    }

    private var status: (text: String, color: Color) {
        if busy { return (service.isRunning ? "Working…" : "Starting…", .orange) }
        switch service.state {
        case "running":
            switch service.healthy {
            case .some(true): return ("Running · Healthy", .green)
            case .some(false): return ("Running · Starting up", .orange)
            case .none: return ("Running", .green)
            }
        case "not_created": return ("Not created", .secondary)
        case "stopping": return ("Stopping…", .orange)
        default: return ("Stopped", .secondary)
        }
    }

    /// "access_key" → "Access key" (the value itself is never shown in the menu).
    private static func label(_ key: String) -> String {
        key.replacingOccurrences(of: "_", with: " ").capitalizedFirst
    }

    @ViewBuilder private var menu: some View {
        Button("Details…", systemImage: "info.circle") { openWindow.focused(id: "service", value: service.id) }
        Button("Logs", systemImage: "text.alignleft") { openWindow.focused(id: "logs", value: service.id) }
            .disabled(service.state == "not_created")
        if !model.manageTitles(service.id).isEmpty {
            Button("Manage \(model.manageTitles(service.id))…", systemImage: "square.stack.3d.up") {
                openWindow.focused(id: "service", value: "\(service.id)/Manage")
            }
            .disabled(!service.isRunning)
        }
        if !service.connection.isEmpty {
            Divider()
            let entries = service.connection.sorted(by: { $0.key < $1.key })
            if entries.count == 1, let e = entries.first {
                Button("Copy \(Self.label(e.key))", systemImage: "doc.on.doc") { model.copy(e.value) }
            } else {
                Menu("Copy connection", systemImage: "doc.on.doc") {
                    ForEach(entries, id: \.key) { key, value in
                        Button(Self.label(key)) { model.copy(value) }
                    }
                }
            }
        }
        if let admin = service.adminURL, let url = URL(string: admin) {
            Button("Open web UI", systemImage: "safari") { openURL(url) }
        }
        Divider()
        if model.tailnet.loggedIn, service.isRunning || service.shared {
            Button(service.shared ? "Stop sharing with other Macs" : "Share with other Macs",
                   systemImage: "antenna.radiowaves.left.and.right") { model.setShared(service, !service.shared) }
                .disabled(busy)
        }
        Button("Restart", systemImage: "arrow.clockwise") { model.restart(service.id) }.disabled(!service.isRunning)
        Button("Update to latest image", systemImage: "arrow.down.circle") { model.pullLatest(service.id) }
    }
}

// MARK: - Projects

struct ProjectsSection: View {
    @Environment(AppModel.self) private var model
    @State private var creating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Projects") {
                Button { creating = true } label: { Label("New Project", systemImage: "plus") }
                    .buttonStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(.tint)
                    .popover(isPresented: $creating, arrowEdge: .trailing) { NewProjectForm { creating = false } }
            }
            if let hosts = model.hosts, !hosts.routerRunning {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(hosts.routerError ?? "The *.\(hosts.domain) router isn't running").font(.caption).lineLimit(2)
                }
            }
            if model.projects.isEmpty {
                Text("A project is an app you're building. Give each part of it, like an api or a portal, a port and a hostname.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            VStack(spacing: 8) {
                ForEach(model.projects) { ProjectTile(project: $0) }
            }
        }
    }
}

struct ProjectTile: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let project: ProjectView
    @State private var expanded: Bool
    @State private var adding = false
    @State private var confirmDelete = false

    init(project: ProjectView) {
        self.project = project
        _expanded = State(initialValue: project.endpoints.isEmpty)
    }

    private var anyUp: Bool { project.endpoints.contains(where: \.up) }

    private var subtitle: String {
        project.endpoints.isEmpty ? "No endpoints yet" : project.endpoints.map(\.name).joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                    HStack(spacing: 12) {
                        StatusDot(color: anyUp ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(project.name).font(.body.weight(.medium))
                            Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)

                Menu { menu } label: { MoreMenuLabel() }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
            }

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(project.endpoints) { e in
                        Button { if let u = URL(string: e.url) { openURL(u) } } label: {
                            HStack(spacing: 8) {
                                StatusDot(color: e.up ? .green : .secondary)
                                Text(e.host).font(.callout)
                                Spacer(minLength: 6)
                                Text(":\(String(e.port))").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .pointerStyle(.link)
                        .help(e.up ? "Open \(e.url)" : "Open \(e.url) — nothing is listening on :\(e.port) yet")
                        .contextMenu {
                            Button("Copy URL", systemImage: "doc.on.doc") { model.copy(e.url) }
                            Button("Remove endpoint", systemImage: "trash", role: .destructive) {
                                model.removeEndpoint(project: project.name, name: e.name)
                            }
                        }
                    }
                    if !project.resources.isEmpty {
                        Text("Uses " + project.resources.map(\.label).joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Button { adding = true } label: { Label("Add endpoint", systemImage: "plus") }
                        .buttonStyle(.plain)
                        .font(.callout)
                        .foregroundStyle(.tint)
                        .popover(isPresented: $adding, arrowEdge: .trailing) {
                            AddEndpointForm(project: project, suggestedPort: model.hosts?.suggestedPort ?? 3000) { adding = false }
                        }
                }
                .padding(.leading, 19)
            }
        }
        .alert("Delete \(project.name)?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { model.deleteProject(project.name) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its hostnames stop working. Databases, buckets and other resources it uses are kept.")
        }
    }

    @ViewBuilder private var menu: some View {
        ForEach(project.endpoints) { e in
            Button("Open \(e.host)", systemImage: "safari") { if let u = URL(string: e.url) { openURL(u) } }
        }
        Button("Add endpoint…", systemImage: "plus") { expanded = true; adding = true }
        Divider()
        Button("Copy .env", systemImage: "doc.on.clipboard") { model.copy(project.env) }
        if !project.endpoints.isEmpty {
            Menu("Remove endpoint", systemImage: "minus.circle") {
                ForEach(project.endpoints) { e in
                    Button(e.name, role: .destructive) { model.removeEndpoint(project: project.name, name: e.name) }
                }
            }
        }
        Divider()
        Button("Delete project…", systemImage: "trash", role: .destructive) { confirmDelete = true }
    }
}

struct NewProjectForm: View {
    @Environment(AppModel.self) private var model
    let done: () -> Void
    @State private var name = ""

    private var valid: Bool { name.wholeMatch(of: /[a-z0-9][a-z0-9-]{1,40}[a-z0-9]/) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New project").font(.headline)
            TextField("Name, e.g. proposal-generator", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(create)
            Text("Lowercase letters, digits and hyphens. You add its ports and hostnames next.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if model.busy.contains("project") { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", action: done)
                Button("Create", action: create)
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!valid || model.busy.contains("project"))
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private func create() {
        guard valid else { return }
        Task { if await model.createProject(name: name) != nil { done() } }
    }
}

struct AddEndpointForm: View {
    @Environment(AppModel.self) private var model
    let project: ProjectView
    let suggestedPort: Int
    let done: () -> Void
    @State private var name = ""
    @State private var port = ""
    @State private var hostname = ""

    private var label: String { name.lowercased() }
    private var defaultHost: String { "\(label.isEmpty ? "api" : label).\(project.name)" }
    private var host: String { (hostname.isEmpty ? defaultHost : hostname.lowercased()) + ".\(model.hosts?.domain ?? "localhost")" }
    private var portValue: Int { Int(port) ?? suggestedPort }
    private var valid: Bool { label.wholeMatch(of: /[a-z][a-z0-9-]{0,20}/) != nil && (port.isEmpty || Int(port) != nil) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New endpoint").font(.headline)
            TextField("Name, e.g. api or portal", text: $name).textFieldStyle(.roundedBorder)
            HStack(spacing: 6) {
                Text("Port").foregroundStyle(.secondary)
                TextField(String(suggestedPort), text: $port).textFieldStyle(.roundedBorder).frame(width: 80)
                Text("your app listens on").font(.caption).foregroundStyle(.secondary)
            }
            TextField("Hostname (default \(defaultHost))", text: $hostname).textFieldStyle(.roundedBorder)
            Text("http://\(host) → localhost:\(String(portValue))")
                .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
            HStack {
                Spacer()
                Button("Cancel", action: done)
                Button("Add") {
                    model.addEndpoint(project: project.name, name: label, port: portValue, hostname: hostname.isEmpty ? nil : hostname.lowercased())
                    done()
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!valid)
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}

// MARK: - Usage

struct UsagePanel: View {
    @Environment(AppModel.self) private var model

    private var running: [ServiceView] { model.services.filter(\.isRunning) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("Usage")
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 0) {
                    metric("Memory", "memorychip", .purple, Format.bytes(model.totalMemory))
                    divider
                    metric("CPU", "cpu", .blue, Format.percent(model.totalCPU))
                    divider
                    metric("Network", "globe", .green, Format.rate(model.networkRate))
                    divider
                    metric("Disk", "internaldrive", .orange, model.diskBytes.map { Format.bytes(Double($0)) } ?? "—")
                }
                if running.isEmpty {
                    Text("Nothing is running.").font(.callout).foregroundStyle(.tertiary)
                } else {
                    Divider()
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                        GridRow {
                            Text("Service").frame(maxWidth: .infinity, alignment: .leading).gridColumnAlignment(.leading)
                            Text("Memory").gridColumnAlignment(.trailing)
                            Text("CPU").gridColumnAlignment(.trailing)
                        }
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        ForEach(running) { s in
                            let st = model.stats[s.id]
                            GridRow {
                                HStack(spacing: 10) {
                                    StatusDot(color: s.tint)
                                    Text(s.name).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Text(Format.bytes(Double(st?.memoryBytes ?? 0))).foregroundStyle(.secondary)
                                Text(Format.percent(st?.cpuPercent ?? 0)).foregroundStyle(.secondary)
                            }
                            .font(.callout.monospacedDigit())
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 16))
        }
    }

    private var divider: some View {
        Rectangle().fill(.quaternary).frame(width: 1, height: 44).padding(.horizontal, 7)
    }

    private func metric(_ title: String, _ icon: String, _ color: Color, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.subheadline.weight(.semibold)).foregroundStyle(color).lineLimit(1)
            Text(value).font(.body.weight(.medium)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help(help)
    }
}

struct PeersSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("Other Macs")
            VStack(spacing: 10) {
                ForEach(model.peers, id: \.name) { peer in
                    let shared = (model.peerServices[peer.name] ?? []).filter(\.shared)
                    HStack(spacing: 12) {
                        StatusDot(color: peer.online ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(peer.name.replacingOccurrences(of: "space-", with: ""))
                                .font(.body.weight(.medium))
                                .foregroundStyle(peer.online ? .primary : .secondary)
                            Text(subtitle(online: peer.online, shared: shared))
                                .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        if peer.online {
                            Button("Control") { model.host = peer.name }
                                .buttonStyle(.bordered)
                                .help("Show and control this Mac's services")
                        }
                    }
                }
            }
        }
    }

    private func subtitle(online: Bool, shared: [RemoteService]) -> String {
        if !online { return "Offline · nothing shared" }
        return shared.isEmpty ? "Nothing shared" : "Shares " + shared.map(\.name).joined(separator: ", ")
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
        .background(.orange.opacity(0.12), in: .rect(cornerRadius: 12))
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
        .background(.red.opacity(0.15), in: .rect(cornerRadius: 12))
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
