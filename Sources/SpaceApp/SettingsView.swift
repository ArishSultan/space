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

    var body: some View {
        Form {
            Section {
                Toggle("Open Space at login", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { model.launcher.opensAtLogin = openAtLogin }
                KeyboardShortcuts.Recorder("Open the Space panel:", name: .togglePanel)
            }
            Section("Background service") {
                LabeledContent("Status", value: model.daemonUp ? "Running" : "Not running")
                LabeledContent("Data & definitions", value: SpacePaths.root.path)
                Button("Show in Finder") { openURL(SpacePaths.root) }
            }
            Section("Agents (MCP)") {
                Text("Let coding agents manage your services, databases, buckets, projects and test emails.")
                    .foregroundStyle(.secondary)
                CopyRow(label: "Claude Code", value: "claude mcp add space -- \(Bundle.main.executableURL!.deletingLastPathComponent().appending(path: "spaced").path) mcp")
                CopyRow(label: "HTTP", value: "http://127.0.0.1:\(SpaceAPI.defaultPort)/mcp")
            }
        }
        .formStyle(.grouped)
        .onAppear { openAtLogin = model.launcher.opensAtLogin }
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
                    LabeledContent("Sites", value: "\(h.sites.filter { !$0.service }.count)")
                    LabeledContent("Service sites", value: "\(h.sites.filter(\.service).count)")
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
        }
        .formStyle(.grouped)
    }
}
