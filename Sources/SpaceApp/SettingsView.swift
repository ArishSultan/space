import SpaceCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var openAtLogin = false

    var body: some View {
        Form {
            Section("General") {
                Toggle("Open Space at login", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { model.launcher.opensAtLogin = openAtLogin }
                LabeledContent("Background service", value: model.daemonUp ? "Running" : "Not running")
                LabeledContent("Data & definitions", value: SpacePaths.root.path)
                Button("Show in Finder") { openURL(SpacePaths.root) }
            }
            Section("Local hostnames (http://*.localhost)") {
                if let h = model.hosts {
                    LabeledContent("Router", value: h.routerRunning ? "Listening on port \(String(h.routerPort))" : "Not running")
                    if let error = h.routerError {
                        Text(error).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    LabeledContent("Sites", value: "\(h.sites.filter { !$0.service }.count)")
                    LabeledContent("Service sites", value: "\(h.sites.filter(\.service).count)")
                    Text("Browsers resolve *.localhost to this Mac on their own — no DNS, certificates or password needed.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Other Macs (Tailscale)") {
                if model.tailnet.loggedIn {
                    LabeledContent("This Mac", value: model.tailnet.me?.name ?? "")
                    LabeledContent("Tailnet", value: model.tailnet.tailnet ?? "")
                    LabeledContent("Space devices", value: "\(model.peers.count)")
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
        .frame(width: 460)
        .onAppear { openAtLogin = model.launcher.opensAtLogin }
    }
}
