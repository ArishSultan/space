import SpaceCore
import SwiftUI

extension Color {
    /// `#RRGGBB` → Color (nil for anything else).
    init?(hex: String?) {
        guard let hex, hex.hasPrefix("#"), hex.count == 7, let v = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

extension ServiceView {
    var tint: Color { Color(hex: color) ?? .accentColor }
    var symbol: String { icon ?? "shippingbox.fill" }
}

/// Official service logo (served by spaced), shown as-is; SF Symbol fallback.
/// Shows a small orange badge only while the service is starting up.
struct ServiceIcon: View {
    let service: ServiceView
    var size: CGFloat = 30

    private var logoURL: URL { SpaceAPI().base.appending(path: "services/\(service.id)/logo") }

    var body: some View {
        AsyncImage(url: logoURL) { phase in
            if let image = phase.image {
                image.resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: service.symbol)
                    .font(.system(size: size * 0.6, weight: .semibold))
                    .foregroundStyle(service.tint)
            }
        }
        .frame(width: size, height: size)
        .opacity(service.isRunning ? 1 : 0.6)
        .overlay(alignment: .bottomTrailing) {
            if service.isRunning, service.healthy == false {
                Circle()
                    .fill(.orange)
                    .frame(width: size * 0.3, height: size * 0.3)
                    .overlay(Circle().stroke(.background, lineWidth: 2))
                    .offset(x: 3, y: 3)
                    .help("Starting up")
            }
        }
    }
}

extension TailnetMark {
    /// Menus flatten custom label views, so render the mark to an image first.
    @MainActor static func image(color: Color, dot: CGFloat = 3.6) -> Image {
        let renderer = ImageRenderer(content: TailnetMark(color: color, dot: dot))
        renderer.scale = 2
        guard let cg = renderer.cgImage else { return Image(systemName: "circle.grid.3x3.fill") }
        return Image(decorative: cg, scale: 2)
    }
}

/// Tailscale-style 3×3 dot mark; the "T" dots light up in the status colour.
struct TailnetMark: View {
    let color: Color
    var dot: CGFloat = 3.6

    private let lit: Set<Int> = [0, 1, 2, 4, 7]

    var body: some View {
        Grid(horizontalSpacing: dot * 0.55, verticalSpacing: dot * 0.55) {
            ForEach(0..<3) { row in
                GridRow {
                    ForEach(0..<3) { col in
                        Circle()
                            .fill(color.opacity(lit.contains(row * 3 + col) ? 1 : 0.3))
                            .frame(width: dot, height: dot)
                    }
                }
            }
        }
    }
}

extension OpenWindowAction {
    /// Opens a window and brings Space to the front (menu-bar apps otherwise open windows behind other apps;
    /// SwiftUI has no activation API, so this uses NSApplication).
    @MainActor func focused(id: String, value: String) {
        callAsFunction(id: id, value: value)
        NSApplication.shared.activate()
    }
}

/// Shows the "clients are connected" confirmation for operations started from `origin`.
struct ConnectedClientsAlert: ViewModifier {
    @Environment(AppModel.self) private var model
    let origin: String

    func body(content: Content) -> some View {
        let item = model.confirmation?.origin == origin ? model.confirmation : nil
        content.alert(
            item.map { "\($0.serviceName) has \($0.clients.count) connected client\($0.clients.count == 1 ? "" : "s")" } ?? "",
            isPresented: Binding(get: { item != nil }, set: { if !$0 { model.confirmation = nil } }),
            presenting: item
        ) { c in
            Button("\(c.verb) anyway", role: .destructive) { c.proceed(); model.confirmation = nil }
            Button("Cancel", role: .cancel) { model.confirmation = nil }
        } message: { c in
            let shown = c.clients.clients.prefix(8)
            let more = c.clients.clients.count - shown.count
            Text((Array(shown) + (more > 0 ? ["and \(more) more…"] : [])).joined(separator: "\n")
                 + "\n\nThey will be disconnected.")
        }
    }
}

/// Confirmations inside the menu-bar panel (see `AppModel.PanelAlert`): "clients are connected" for operations
/// started from the panel, and any alert a panel row asks for. Drawn as an overlay, so focus never leaves the panel.
struct PanelAlerts: ViewModifier {
    @Environment(AppModel.self) private var model

    private var current: AppModel.PanelAlert? {
        if let alert = model.panelAlert { return alert }
        guard let c = model.confirmation, c.origin == "popover" else { return nil }
        let shown = c.clients.clients.prefix(8)
        let more = c.clients.clients.count - shown.count
        return .init(
            title: "\(c.serviceName) has \(c.clients.count) connected client\(c.clients.count == 1 ? "" : "s")",
            message: (Array(shown) + (more > 0 ? ["and \(more) more…"] : [])).joined(separator: "\n") + "\n\nThey will be disconnected.",
            confirm: "\(c.verb) anyway", action: c.proceed)
    }

    private func dismiss() {
        model.panelAlert = nil
        if model.confirmation?.origin == "popover" { model.confirmation = nil }
    }

    func body(content: Content) -> some View {
        content
            .overlay {
                if let alert = current {
                    ZStack {
                        Rectangle().fill(.black.opacity(0.28)).onTapGesture(perform: dismiss)
                        VStack(spacing: 12) {
                            Text(alert.title).font(.headline).multilineTextAlignment(.center)
                            ScrollView {
                                Text(alert.message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                                    .frame(maxWidth: .infinity)
                            }
                            .frame(maxHeight: 160)
                            .fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 8) {
                                Button("Cancel", action: dismiss)
                                    .keyboardShortcut(.cancelAction)
                                Button(alert.confirm) { alert.action(); dismiss() }
                                    .buttonStyle(.glassProminent)
                                    .tint(alert.destructive ? .red : nil)
                                    .keyboardShortcut(.defaultAction)
                            }
                            .buttonStyle(.glass)
                        }
                        .padding(18)
                        .frame(width: 320)
                        .glassEffect(in: .rect(cornerRadius: 18))
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: current?.title)
    }
}

extension View {
    func panelAlerts() -> some View { modifier(PanelAlerts()) }
    func connectedClientsAlert(origin: String) -> some View { modifier(ConnectedClientsAlert(origin: origin)) }
}
