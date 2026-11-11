import KeyboardShortcuts
import SpaceCore
import SwiftUI

extension KeyboardShortcuts.Name {
    /// Opens the Space panel as a floating window from anywhere.
    static let togglePanel = Self("togglePanel", default: .init(.s, modifiers: [.control, .option]))
}

struct SettingsView: View {
    @State private var tab = ProcessInfo.processInfo.environment["SPACE_PREVIEW_TAB"] ?? "General"

    var body: some View {
        TabView(selection: $tab) {
            Tab("General", systemImage: "gearshape", value: "General") { GeneralSettings() }
            Tab("Apps", systemImage: "square.grid.2x2", value: "Apps") { AppsSettings() }
            Tab("Storage", systemImage: "internaldrive", value: "Storage") { StorageSettings() }
            Tab("Network", systemImage: "network", value: "Network") { NetworkSettings() }
        }
        .frame(width: 560, height: 520)
        .connectedClientsAlert(origin: "settings")
    }
}

// MARK: - General

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var openAtLogin = false
    @State private var agents = AgentSetup()
    @Environment(AppUpdater.self) private var updater

    var body: some View {
        Form {
            Section {
                Toggle("Open Space at login", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { model.launcher.opensAtLogin = openAtLogin }
                LabeledContent("Open the Space panel") { ShortcutRecorder(name: .togglePanel) }
            }
            Section("Updates") {
                @Bindable var updater = updater
                LabeledContent("Version", value: updater.version)
                if updater.isAvailable {
                    Toggle("Check for updates automatically", isOn: $updater.automaticallyChecks)
                    Toggle("Install updates automatically", isOn: $updater.automaticallyInstalls)
                        .disabled(!updater.automaticallyChecks)
                    Button("Check for Updates…") { updater.checkForUpdates() }
                } else {
                    Text("Updates are delivered to the installed app, not to development builds.")
                        .foregroundStyle(.secondary)
                }
            }
            Section("Background service") {
                LabeledContent("Status", value: model.daemonUp ? "Running" : "Not running")
                LabeledContent("Data & definitions", value: SpacePaths.root.path)
                Button("Show in Finder") { openURL(SpacePaths.root) }
            }
            Section("Agents (MCP)") {
                Text("Let coding agents manage your services, databases, buckets, projects and test emails.")
                    .foregroundStyle(.secondary)
                AgentRow(name: "Claude Code", detail: "CLI · every project", state: agents.claudeCode, busy: agents.busy,
                         missing: "Not installed") { on in Task { await agents.setClaudeCode(on) } }
                AgentRow(name: "Claude Desktop", detail: "Restart the app after adding", state: agents.desktop, busy: agents.busy,
                         missing: "Not installed") { on in Task { await agents.setDesktop(on) } }
                if let message = agents.message {
                    Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                CopyRow(label: "Claude Code", value: "claude mcp add space -- \(Bundle.main.executableURL!.deletingLastPathComponent().appending(path: "spaced").path) mcp")
                CopyRow(label: "HTTP", value: "http://127.0.0.1:\(SpaceAPI.defaultPort)/mcp")
            }
        }
        .formStyle(.grouped)
        .onAppear { openAtLogin = model.launcher.opensAtLogin }
        .task { await agents.refresh() }
    }
}

// MARK: - Apps

struct AppsSettings: View {
    @Environment(AppModel.self) private var model

    private var visible: [ImageSetting] { model.images.filter { !$0.hidden } }

    var body: some View {
        Form {
            Section {
                ForEach(visible) { AppSettingRow(setting: $0) }
            } header: {
                Text("Choose which apps appear in the panel, and which image each one runs.")
            } footer: {
                Text("A new image applies the next time you update that app. Updating pulls the newest image and keeps your data (Postgres and MongoDB are backed up first).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("Update all apps", systemImage: "arrow.down.circle") { model.updateAll() }
                        .buttonStyle(.glassProminent)
                        .disabled(model.maintenanceBusy != nil)
                    if let busy = model.maintenanceBusy { ProgressView().controlSize(.small); Text(busy).foregroundStyle(.secondary) }
                }
            }
        }
        .formStyle(.grouped)
        .task { await model.loadMaintenance() }
    }
}

struct AppSettingRow: View {
    @Environment(AppModel.self) private var model
    let setting: ImageSetting
    @State private var image = ""

    private var service: ServiceView? { model.services.first { $0.id == setting.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if let service { ServiceIcon(service: service, size: 24) }
                Text(setting.name).font(.body.weight(.medium))
                Spacer()
                Text("Show in panel").foregroundStyle(.secondary)
                Toggle("Show in panel", isOn: Binding(
                    get: { !model.hiddenInPanel.contains(setting.id) },
                    set: { if $0 { model.hiddenInPanel.remove(setting.id) } else { model.hiddenInPanel.insert(setting.id) } }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
            }
            HStack(spacing: 6) {
                TextField("Image", text: $image, prompt: Text(setting.defaultImage))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
                    .font(.callout.monospaced())
                    .onSubmit { model.setImage(setting.id, image) }
                if image != setting.image {
                    Button("Save") { model.setImage(setting.id, image) }.buttonStyle(.glassProminent)
                }
                if setting.overridden {
                    Button("Reset") { image = setting.defaultImage; model.setImage(setting.id, nil) }
                        .help("Back to \(setting.defaultImage)")
                }
                Button("Update", systemImage: "arrow.down.circle") { model.pullLatest(setting.id, origin: "settings") }
                    .labelStyle(.iconOnly)
                    .help("Pull the latest \(setting.image) and recreate (data kept)")
                    .disabled(service?.state == "not_created" || model.busy.contains(setting.id))
                if model.busy.contains(setting.id) { ProgressView().controlSize(.small) }
            }
            .buttonStyle(.glass)
        }
        .padding(.vertical, 2)
        .onAppear { image = setting.image }
        .onChange(of: setting.image) { image = setting.image }
    }
}

// MARK: - Storage

struct StorageSettings: View {
    @Environment(AppModel.self) private var model
    @State private var confirmData = false

    var body: some View {
        Form {
            if let d = model.disk {
                Section("Used by containers") {
                    LabeledContent("Images", value: "\(Format.bytes(Double(d.images.sizeInBytes))) · \(Format.bytes(Double(d.images.reclaimable))) unused")
                    LabeledContent("Containers", value: "\(Format.bytes(Double(d.containers.sizeInBytes))) · \(Format.bytes(Double(d.containers.reclaimable))) reclaimable")
                }
                Section("App data") {
                    if d.spaceVolumes.isEmpty { Text("No data yet").foregroundStyle(.secondary) }
                    ForEach(d.spaceVolumes, id: \.name) { v in
                        let name = model.services.first { $0.id == v.service }?.name ?? v.service
                        let suffix = v.name.replacingOccurrences(of: "space-\(v.service)-", with: "")
                        LabeledContent(suffix == "data" ? name : "\(name) (\(suffix))", value: Format.bytes(Double(v.bytes)))
                    }
                }
            } else {
                ProgressView()
            }
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Reclaim space removes stopped app containers and app images nothing uses (they download again when needed). Your data is kept.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button("Reclaim space", systemImage: "sparkles") { model.reclaim(includeData: false) }
                            .buttonStyle(.glassProminent)
                        Button("Also delete data of stopped apps…", role: .destructive) { confirmData = true }
                            .buttonStyle(.glass)
                    }
                    .disabled(model.maintenanceBusy != nil)
                    if let busy = model.maintenanceBusy { HStack { ProgressView().controlSize(.small); Text(busy) } }
                    if let r = model.lastReclaim {
                        Text("Freed \(Format.bytes(Double(r.freedBytes))) · removed \(r.removed.count) item\(r.removed.count == 1 ? "" : "s")")
                            .font(.callout.weight(.medium)).foregroundStyle(.green)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { await model.loadMaintenance() }
        .alert("Delete data of stopped apps?", isPresented: $confirmData) {
            Button("Delete data", role: .destructive) { model.reclaim(includeData: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Databases, buckets and messages of every app that isn't running are permanently deleted. Running apps keep their data.")
        }
    }
}

// MARK: - Network

struct NetworkSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            Section("Local hostnames (http://*.localhost)") {
                if let h = model.hosts {
                    LabeledContent("Router", value: h.routerRunning ? "Listening on port \(String(h.routerPort))" : "Not running")
                    if let error = h.routerError {
                        Text(error).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    LabeledContent("Project hostnames", value: "\(h.sites.filter { !$0.service }.count)")
                    LabeledContent("Service hostnames", value: "\(h.sites.filter(\.service).count)")
                    Text("Browsers resolve *.localhost to this Mac on their own — no DNS, certificates or password needed. Only this Mac can use the router.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Other Macs (Tailscale)") {
                if model.tailnet.loggedIn {
                    LabeledContent("This Mac", value: model.tailnet.me?.name ?? "")
                    LabeledContent("Tailnet", value: model.tailnet.tailnet ?? "")
                    LabeledContent("Space devices", value: "\(model.peers.count)")
                    Text("Only devices signed in with your Tailscale account can use shared services.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Log out", role: .destructive) { model.logout() }
                } else {
                    Text("Log in once to use services across your Macs. No Tailscale app needed.")
                        .foregroundStyle(.secondary)
                    Button(model.loggingIn ? "Waiting for browser…" : "Log in with Tailscale") { model.login(open: openURL) }
                        .disabled(model.loggingIn)
                }
            }
            if model.tailnet.loggedIn {
                Section {
                    let online = model.peers.filter(\.online)
                    if online.isEmpty { Text("No other Macs are online.").foregroundStyle(.secondary) }
                    ForEach(online, id: \.name) { peer in
                        let shared = (model.peerServices[peer.name] ?? []).filter(\.shared)
                        ForEach(shared) { service in
                            MountRow(peer: peer.name, service: service)
                        }
                    }
                } header: {
                    Text("Use services from other Macs")
                } footer: {
                    Text("Turn one on to reach it on this Mac's localhost, with the connection strings rewritten to local ports.")
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Shortcut recorder

/// Native recorder for a global shortcut. (KeyboardShortcuts' own Recorder loads its localized strings from a
/// SwiftPM resource bundle that can't live inside a signed .app, so we only use the package for registration.)
struct ShortcutRecorder: View {
    let name: KeyboardShortcuts.Name
    @State private var shortcut: KeyboardShortcuts.Shortcut?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button {
                recording ? stop() : start()
            } label: {
                Text(recording ? "Press keys…" : (shortcut.map(Self.label) ?? "Record shortcut"))
                    .monospaced()
                    .frame(minWidth: 110)
            }
            .buttonStyle(.glass)
            .help(recording ? "Press a key with ⌘, ⌥ or ⌃ — Esc cancels" : "Click to record a new shortcut")
            if shortcut != nil, !recording {
                Button("Clear", systemImage: "xmark.circle.fill") {
                    KeyboardShortcuts.setShortcut(nil, for: name)
                    shortcut = nil
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
        }
        .onAppear { shortcut = KeyboardShortcuts.getShortcut(for: name) }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        KeyboardShortcuts.disable(name)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stop(); return nil }  // Esc cancels
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !mods.subtracting(.shift).isEmpty, let new = KeyboardShortcuts.Shortcut(event: event) else { return nil }
            KeyboardShortcuts.setShortcut(new, for: name)
            shortcut = new
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording { KeyboardShortcuts.enable(name) }
        recording = false
    }

    /// e.g. "⌃⌥S". Built here because the package's Space-key label needs its resource bundle.
    static func label(_ s: KeyboardShortcuts.Shortcut) -> String {
        var out = ""
        if s.modifiers.contains(.control) { out += "⌃" }
        if s.modifiers.contains(.option) { out += "⌥" }
        if s.modifiers.contains(.shift) { out += "⇧" }
        if s.modifiers.contains(.command) { out += "⌘" }
        return out + (s.key == .space ? "Space" : String(s.description.drop { "⌃⌥⇧⌘".contains($0) }))
    }
}

struct MountRow: View {
    @Environment(AppModel.self) private var model
    let peer: String
    let service: RemoteService

    var body: some View {
        let mount = model.mountFor(peer, service.id)
        HStack(spacing: 10) {
            ServiceIcon(service: service, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(service.name) on \(peer.replacingOccurrences(of: "space-", with: ""))")
                Text(mount.map { m in m.localPorts.values.sorted().map { "localhost:\($0)" }.joined(separator: " · ") }
                     ?? (service.isRunning ? "Available" : "Stopped on that Mac"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let mount, let first = mount.connection.sorted(by: { $0.key < $1.key }).first {
                Button("Copy", systemImage: "doc.on.doc") { model.copy(first.value) }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                    .help("Copy \(first.key): \(first.value)")
            }
            Toggle("Use here", isOn: Binding(get: { mount != nil }, set: { model.mount(peer, service.id, $0) }))
                .labelsHidden()
                .disabled(model.busy.contains("\(peer)/\(service.id)"))
        }
    }
}

/// Add / remove Space's MCP server in one client.
struct AgentRow: View {
    let name: String
    let detail: String
    let state: AgentSetup.State
    let busy: Bool
    let missing: String
    let set: (Bool) -> Void

    var body: some View {
        LabeledContent {
            switch state {
            case .unknown: ProgressView().controlSize(.small)
            case .unavailable: Text(missing).foregroundStyle(.secondary)
            case .notAdded: Button("Add") { set(true) }.disabled(busy)
            case .added:
                HStack(spacing: 10) {
                    Label("Added", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Button("Remove") { set(false) }.disabled(busy)
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
