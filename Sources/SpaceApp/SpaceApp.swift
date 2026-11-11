import AppKit
import KeyboardShortcuts
import SwiftUI

@main
struct SpaceApp: App {
    @State private var model = AppModel()

    init() {
        // Menu-bar only, no Dock icon (also set via LSUIElement in the bundle).
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environment(model)
                .task { model.start() }
        } label: {
            Image(systemName: model.runningCount > 0 ? "shippingbox.fill" : "shippingbox")
                .task { model.start() }
                .modifier(PreviewOpener())
                .environment(model)
        }
        .menuBarExtraStyle(.window)

        WindowGroup("Service", id: "service", for: String.self) { $route in
            if let route {
                ServiceWindow(route: route)
                    .environment(model)
            }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 760, height: 560)

        WindowGroup("Logs", id: "logs", for: String.self) { $id in
            if let id {
                LogsWindow(serviceID: id)
                    .environment(model)
            }
        }
        .defaultSize(width: 820, height: 520)

        // The panel as a floating window: opened by the global shortcut (and SPACE_PREVIEW=popover in development).
        Window("Space", id: "preview") {
            PopoverView()
                .environment(model)
                .task { model.start() }
                .onAppear { model.panelWindowOpen = true }
                .onDisappear { model.panelWindowOpen = false }
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .windowLevel(.floating)
        .defaultWindowPlacement { _, _ in
            WindowPlacement(.topTrailing)
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

/// Honors SPACE_PREVIEW=popover|<service id> by opening that view in a regular window at launch.
struct PreviewOpener: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.task {
            // Global shortcut (Settings → General) toggles the floating panel.
            KeyboardShortcuts.onKeyUp(for: .togglePanel) { [model] in
                if model.panelWindowOpen { dismissWindow(id: "preview") }
                else { openWindow(id: "preview"); NSApplication.shared.activate() }
            }
        }
        .task {
            guard let target = ProcessInfo.processInfo.environment["SPACE_PREVIEW"] else { return }
            if target == "popover" { openWindow(id: "preview") }
            else if target == "settings" { NSApplication.shared.activate(); openSettings() }
            else if target.hasPrefix("stop:") {
                // Development aid: ask to stop a service, to preview the connected-clients dialog.
                openWindow(id: "preview")
                try? await Task.sleep(for: .seconds(3))
                if let s = model.services.first(where: { $0.id == target.dropFirst(5) }) { model.setRunning(s, false) }
            }
            else if target.hasPrefix("logs:") { openWindow(id: "logs", value: String(target.dropFirst(5))) }
            else { openWindow(id: "service", value: target) }
        }
    }
}
