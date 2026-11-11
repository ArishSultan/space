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
            Section("Local hostnames (*.space.test)") {
                if let h = model.hosts {
                    LabeledContent("Caddy (proxy)", value: h.caddyInstalled ? (h.proxyRunning ? "Running" : "Installed") : "Not installed")
                    LabeledContent("dnsmasq (DNS)", value: h.dnsmasqInstalled ? (h.dnsRunning ? "Running" : "Installed") : "Not installed")
                    LabeledContent("Resolver", value: h.resolverInstalled ? "Installed" : "Missing")
                    LabeledContent("HTTPS certificate", value: h.certificateTrusted ? "Trusted" : "Not trusted")
                    if !h.caddyInstalled || !h.dnsmasqInstalled {
                        Text("Install with: brew install caddy dnsmasq").font(.callout.monospaced()).textSelection(.enabled)
                    } else if !h.ready {
                        Button(model.settingUpHosts ? "Setting up…" : "Finish setup…") { model.setUpHosts() }
                            .disabled(model.settingUpHosts)
                    }
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
