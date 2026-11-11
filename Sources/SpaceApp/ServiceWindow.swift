import Charts
import SpaceCore
import SwiftUI

struct ServiceWindow: View {
    @Environment(AppModel.self) private var model
    let serviceID: String
    @State private var tab: Tab

    /// `route` is "postgres" or "postgres/Manage" (opens that tab).
    init(route: String) {
        let parts = route.split(separator: "/", maxSplits: 1).map(String.init)
        serviceID = parts[0]
        // SPACE_PREVIEW_TAB lets development screenshots open a specific tab.
        let requested = parts.count > 1 ? parts[1] : ProcessInfo.processInfo.environment["SPACE_PREVIEW_TAB"]
        _tab = State(initialValue: Tab(rawValue: requested ?? "") ?? .overview)
    }
    @State private var recipe: RecipeView?

    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview", manage = "Manage", logs = "Logs", config = "Config"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .overview: "gauge.with.dots.needle.33percent"
            case .logs: "text.alignleft"
            case .config: "slider.horizontal.3"
            case .manage: "square.stack.3d.up"
            }
        }
    }

    private var service: ServiceView? { model.services.first { $0.id == serviceID } }
    private var tabs: [Tab] { (recipe?.recipe.resources ?? []).isEmpty ? [.overview, .logs, .config] : Tab.allCases }

    var body: some View {
        Group {
            if let service {
                VStack(spacing: 0) {
                    ServiceHeader(service: service)
                        .padding([.horizontal, .top], 18)
                        .padding(.bottom, 12)
                    Group {
                        switch tab {
                        case .overview: OverviewTab(service: service)
                        case .logs: LogsTab(serviceID: serviceID)
                        case .config: ConfigTab(serviceID: serviceID, recipe: $recipe)
                        case .manage:
                            if let kinds = recipe?.recipe.resources, !kinds.isEmpty { ManageTab(service: service, kinds: kinds) }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ContentUnavailableView("Unknown service", systemImage: "questionmark.square.dashed")
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("", selection: $tab) {
                    ForEach(tabs) { Label($0.rawValue, systemImage: $0.icon).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelStyle(.titleAndIcon)
                .labelsHidden()
            }
        }
        .navigationTitle(service?.name ?? serviceID)
        .connectedClientsAlert(origin: serviceID)
        .frame(minWidth: 640, minHeight: 440)
        .task { recipe = try? await model.api.get("services/\(serviceID)/recipe") }
        .onAppear { model.visibleSurfaces += 1 }
        .onDisappear { model.visibleSurfaces -= 1 }
    }
}

struct ServiceHeader: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let service: ServiceView

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ServiceIcon(service: service, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(service.name).font(.title2.weight(.semibold))
                Text(service.image).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    if let admin = service.adminURL, let url = URL(string: admin), service.isRunning {
                        Button("Open web UI", systemImage: "safari") { openURL(url) }
                    }
                    Button("Restart", systemImage: "arrow.clockwise") { model.restart(service.id, origin: service.id) }
                        .disabled(!service.isRunning)
                    Button("Update", systemImage: "arrow.down.circle") { model.pullLatest(service.id, origin: service.id) }
                        .help("Pull the latest image and recreate (data is kept)")
                    Button(service.isRunning ? "Stop" : "Start", systemImage: service.isRunning ? "stop.fill" : "play.fill") {
                        model.setRunning(service, !service.isRunning, origin: service.id)
                    }
                    .buttonStyle(.glassProminent)
                }
                .buttonStyle(.glass)
                .disabled(model.busy.contains(service.id))
            }
        }
    }
}

// MARK: - Overview

struct OverviewTab: View {
    @Environment(AppModel.self) private var model
    let service: ServiceView

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !service.connection.isEmpty {
                    Card("Connect") {
                        ForEach(service.connection.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                            CopyRow(label: key, value: value)
                        }
                    }
                }

                if service.isRunning, let samples = model.history[service.id], samples.count > 1 {
                    HStack(spacing: 16) {
                        Card("CPU") { MetricChart(samples: samples, value: \.cpu, format: Format.percent) }
                        Card("Memory") { MetricChart(samples: samples, value: \.memory, format: Format.bytes) }
                    }
                    if let s = model.stats[service.id] {
                        Card("I/O") {
                            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                                GridRow { Text("Network in"); Text(Format.bytes(Double(s.networkRxBytes ?? 0))) }
                                GridRow { Text("Network out"); Text(Format.bytes(Double(s.networkTxBytes ?? 0))) }
                                GridRow { Text("Disk read"); Text(Format.bytes(Double(s.blockReadBytes ?? 0))) }
                                GridRow { Text("Disk written"); Text(Format.bytes(Double(s.blockWriteBytes ?? 0))) }
                                GridRow { Text("Processes"); Text("\(s.processes ?? 0)") }
                            }
                            .font(.callout.monospacedDigit())
                        }
                    }
                } else if !service.isRunning {
                    ContentUnavailableView("Not running", systemImage: "moon.zzz", description: Text("Start the service to see live usage."))
                }
            }
            .padding(18)
        }
    }
}

struct MetricChart: View {
    let samples: [StatSample]
    let value: KeyPath<StatSample, Double>
    let format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(format(samples.last?[keyPath: value] ?? 0)).font(.title3.monospacedDigit().weight(.semibold))
            Chart(samples) {
                AreaMark(x: .value("Time", $0.date), y: .value("Value", $0[keyPath: value]))
                    .foregroundStyle(.linearGradient(colors: [.accentColor.opacity(0.3), .clear], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", $0.date), y: .value("Value", $0[keyPath: value]))
                    .interpolationMethod(.monotone)
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { v in
                    AxisGridLine()
                    AxisValueLabel { if let d = v.as(Double.self) { Text(format(d)) } }
                }
            }
            .chartXAxis(.hidden)
            .frame(height: 120)
        }
    }
}

// MARK: - Logs

struct LogsTab: View {
    @Environment(AppModel.self) private var model
    let serviceID: String
    var standalone = false
    @State private var text = ""
    @State private var filter = ""
    @State private var paused = false
    @State private var follow = true
    @State private var loadError: String?

    private var shown: String {
        guard !filter.isEmpty else { return text }
        return text.split(separator: "\n").filter { $0.localizedCaseInsensitiveContains(filter) }.joined(separator: "\n")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Filter", text: $filter).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Spacer()
                Toggle("Follow", isOn: $follow).toggleStyle(.checkbox)
                Button(paused ? "Resume" : "Pause", systemImage: paused ? "play.fill" : "pause.fill") { paused.toggle() }
                    .buttonStyle(.glass)
                Button("Copy", systemImage: "doc.on.doc") { model.copy(text) }
                    .buttonStyle(.glass)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 10)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(loadError ?? (shown.isEmpty ? "No output yet." : shown))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(shown.isEmpty ? .secondary : .primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(12)
                }
                .defaultScrollAnchor(follow ? .bottom : nil)
                .background(.background.secondary)
                .onChange(of: text) { if follow { proxy.scrollTo("end", anchor: .bottom) } }
            }
        }
        .padding(.top, standalone ? 12 : 0)
        .task(id: serviceID) {
            while !Task.isCancelled {
                if !paused {
                    do {
                        let t: String = try await model.api.get("services/\(serviceID)/logs", query: ["tail": "1000"])
                        if t != text { text = t }
                        loadError = nil
                    } catch {
                        loadError = error.localizedDescription
                    }
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

// MARK: - Config

struct ConfigTab: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let serviceID: String
    @Binding var recipe: RecipeView?
    @State private var applying = false

    var body: some View {
        ScrollView {
            if let rv = recipe {
                let r = rv.recipe
                VStack(alignment: .leading, spacing: 16) {
                    Card("Container") {
                        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                            GridRow { Text("Image").foregroundStyle(.secondary); Text(r.image).textSelection(.enabled) }
                            GridRow { Text("Memory").foregroundStyle(.secondary); Text(r.memory ?? "default") }
                            GridRow { Text("CPUs").foregroundStyle(.secondary); Text(r.cpus.map(String.init) ?? "default") }
                            ForEach(r.ports, id: \.name) { p in
                                GridRow { Text("Port \(p.name)").foregroundStyle(.secondary); Text("localhost:\(String(p.host)) → \(String(p.container))") }
                            }
                            ForEach(r.volumes ?? [], id: \.name) { v in
                                GridRow { Text("Volume").foregroundStyle(.secondary); Text("\(r.volumeName(v)) → \(v.path)") }
                            }
                        }
                    }
                    if let env = r.env, !env.isEmpty {
                        Card("Environment") {
                            ForEach(env.sorted(by: { $0.key < $1.key }), id: \.key) { CopyRow(label: $0.key, value: $0.value) }
                        }
                    }
                    Card("Definition") {
                        Text(rv.overridePath.map { "Using your override: \($0)" } ?? "Using the built-in definition.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(rv.yaml)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(.background.secondary, in: .rect(cornerRadius: 8))
                        HStack {
                            Button("Edit…", systemImage: "square.and.pencil") { edit() }
                                .help("Copies the definition to ~/.config/space/recipes and opens it")
                            Button("Apply changes", systemImage: "checkmark.circle") { apply() }
                                .buttonStyle(.glassProminent)
                                .disabled(applying)
                                .help("Reload definitions and recreate the container (data is kept)")
                            if applying { ProgressView().controlSize(.small) }
                        }
                        .buttonStyle(.glass)
                    }
                }
                .padding(18)
            } else {
                ProgressView().padding(40)
            }
        }
    }

    private func reload() async { recipe = try? await model.api.get("services/\(serviceID)/recipe") }

    private func edit() {
        Task {
            struct P: Decodable { let path: String }
            do {
                let p: P = try await model.api.post("services/\(serviceID)/override")
                openURL(URL(fileURLWithPath: p.path))
                await reload()
            } catch { model.lastError = error.localizedDescription }
        }
    }

    private func apply() {
        applying = true
        Task {
            defer { applying = false }
            do { try await model.api.post("services/\(serviceID)/apply", as: OK.self) }
            catch { model.lastError = error.localizedDescription }
            await reload()
            await model.refresh()
        }
    }
}

// MARK: - Manage (projects, databases, users…)

struct ManageTab: View {
    @Environment(AppModel.self) private var model
    let service: ServiceView
    let kinds: [Recipe.Resources]
    @State private var selected: String = ""

    private var current: Recipe.Resources? { kinds.first { $0.id == selected } ?? kinds.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if kinds.count > 1 {
                Picker("", selection: $selected) {
                    ForEach(kinds) { Text($0.title).tag($0.id) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if !service.isRunning {
                ContentUnavailableView("\(service.name) is stopped", systemImage: "moon.zzz",
                                       description: Text("Start it to manage \(current?.title.lowercased() ?? "items")."))
            } else if let current {
                ResourceList(service: service, resources: current)
                    .id(current.id)
            }
        }
        .padding(18)
        .onAppear { if selected.isEmpty { selected = kinds.first?.id ?? "" } }
    }
}

struct ResourceList: View {
    @Environment(AppModel.self) private var model
    let service: ServiceView
    let resources: Recipe.Resources
    @State private var items: [ServiceManager.Resource] = []
    @State private var newName = ""
    @State private var working = false
    @State private var error: String?
    @State private var confirmDrop: String?

    private var kind: String { resources.kind }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let hint = resources.hint {
                Text(hint).font(.callout).foregroundStyle(.secondary)
            }
            if resources.create != nil {
                HStack {
                    TextField("New \(kind) name", text: $newName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(create)
                    Button("Create \(kind)", systemImage: "plus", action: create)
                        .buttonStyle(.glassProminent)
                        .disabled(newName.isEmpty || working)
                    if working { ProgressView().controlSize(.small) }
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }

            if items.isEmpty, error == nil {
                ContentUnavailableView("No \(resources.title.lowercased()) yet", systemImage: "tray",
                                       description: Text("Create one above."))
            } else {
                List(items, id: \.name) { item in
                    HStack(spacing: 10) {
                        Text(item.name).font(.body.weight(.medium))
                        if (resources.protected ?? []).contains(item.name) {
                            Text("built-in").font(.caption2).foregroundStyle(.secondary)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(.quaternary, in: .capsule)
                        }
                        Spacer()
                        if let c = item.connection {
                            Text(c).font(.caption.monospaced()).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                            Button("Copy", systemImage: "doc.on.doc") { model.copy(c) }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.glass)
                                .buttonBorderShape(.circle)
                                .help("Copy connection string")
                        }
                        if resources.drop != nil, !(resources.protected ?? []).contains(item.name) {
                            Button("Delete", systemImage: "trash", role: .destructive) { confirmDrop = item.name }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.glass)
                                .buttonBorderShape(.circle)
                                .help("Delete \(kind)")
                        }
                    }
                    .padding(.vertical, 3)
                }
                .scrollContentBackground(.hidden)
            }
        }
        .task { await load() }
        .confirmationDialog("Delete \(kind) “\(confirmDrop ?? "")”? Its data is removed.",
                            isPresented: Binding(get: { confirmDrop != nil }, set: { if !$0 { confirmDrop = nil } })) {
            Button("Delete", role: .destructive) { if let n = confirmDrop { drop(n) } }
        }
    }

    private func load() async {
        do { items = try await model.api.get("services/\(service.id)/resources/\(resources.id)"); error = nil }
        catch { self.error = error.localizedDescription }
    }

    private func run(_ action: String, _ name: String) {
        working = true
        Task {
            defer { working = false }
            do {
                let r: ServiceManager.ActionResult = try await model.api.post("services/\(service.id)/actions/\(action)",
                                                                              body: ActionRequest(params: ["name": name]))
                error = r.ok ? nil : r.output
            } catch { self.error = error.localizedDescription }
            await load()
        }
    }

    private func create() {
        guard !newName.isEmpty, let action = resources.create else { return }
        run(action, newName)
        newName = ""
    }

    private func drop(_ name: String) {
        guard let action = resources.drop else { return }
        run(action, name)
    }
}

// MARK: - Building blocks

struct Card<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(in: .rect(cornerRadius: 16))
    }
}

struct CopyRow: View {
    @Environment(AppModel.self) private var model
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary).frame(minWidth: 80, alignment: .leading)
            Text(value).font(.callout.monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button("Copy", systemImage: "doc.on.doc") { model.copy(value) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
    }
}

// MARK: - Standalone logs window

/// Independent, resizable logs window opened from the popover's logs button.
struct LogsWindow: View {
    @Environment(AppModel.self) private var model
    let serviceID: String

    private var service: ServiceView? { model.services.first { $0.id == serviceID } }

    var body: some View {
        LogsTab(serviceID: serviceID, standalone: true)
            .navigationTitle("\(service?.name ?? serviceID) Logs")
            .frame(minWidth: 560, minHeight: 360)
            .onAppear { model.visibleSurfaces += 1 }
            .onDisappear { model.visibleSurfaces -= 1 }
    }
}
