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
    private var tabs: [Tab] {
        guard let r = recipe?.recipe else { return [.overview, .logs, .config] }
        return (r.resources ?? []).isEmpty && r.visibleActions.isEmpty ? [.overview, .logs, .config] : Tab.allCases
    }

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
                            if let r = recipe?.recipe { ManageTab(service: service, recipe: r) }
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

    static let maxLines = 5000

    private func append(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        var all = text.isEmpty ? [] : text.components(separatedBy: "\n")
        all.append(contentsOf: lines)
        if all.count > Self.maxLines { all.removeFirst(all.count - Self.maxLines) }
        text = all.joined(separator: "\n")
    }

    private func stream() async {
        while !Task.isCancelled {
            do {
                text = ""
                loadError = nil
                let url = model.api.base.appending(path: "services/\(serviceID)/logs/stream").appending(queryItems: [.init(name: "tail", value: "1000")])
                let (bytes, _) = try await URLSession.shared.bytes(from: url)
                var pending: [String] = []
                var lastFlush = ContinuousClock.now
                for try await line in bytes.lines {
                    guard line.hasPrefix("data: ") else { continue }
                    pending.append(String(line.dropFirst(6)))
                    // Batch UI updates (the initial backlog arrives all at once).
                    if ContinuousClock.now - lastFlush > .milliseconds(150) {
                        if !paused { append(pending) }
                        pending.removeAll(keepingCapacity: true)
                        lastFlush = .now
                    }
                }
                if !paused { append(pending) }
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                loadError = error.localizedDescription
            }
            try? await Task.sleep(for: .seconds(2))  // container stopped/restarted: reconnect
        }
    }

    private func poll() async {
        while !Task.isCancelled {
            if !paused {
                do {
                    let t: String = try await model.api.get("services/\(serviceID)/logs", query: ["tail": "1000"])
                    if t != text { text = t }
                    loadError = nil
                } catch { loadError = error.localizedDescription }
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

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
            // Live stream (server-sent events) from this Mac's daemon; other Macs are polled through the proxy.
            if model.isRemote { await poll() } else { await stream() }
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
    let recipe: Recipe
    @State private var selected: String = ""

    private var kinds: [Recipe.Resources] { recipe.resources ?? [] }
    private var segments: [(id: String, title: String)] {
        kinds.map { ($0.id, $0.title) } + (recipe.visibleActions.isEmpty ? [] : [("__actions", "Actions")])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if segments.count > 1 {
                Picker("", selection: $selected) {
                    ForEach(segments, id: \.id) { Text($0.title).tag($0.id) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if !service.isRunning {
                ContentUnavailableView("\(service.name) is stopped", systemImage: "moon.zzz",
                                       description: Text("Start it to manage it."))
            } else if selected == "__actions" {
                ActionsPanel(service: service, actions: recipe.visibleActions)
            } else if let current = kinds.first(where: { $0.id == selected }) {
                ResourceList(service: service, resources: current)
                    .id(current.id)
            }
        }
        .padding(18)
        .onAppear { if selected.isEmpty { selected = segments.first?.id ?? "" } }
    }
}

extension Recipe {
    /// Actions worth a button: not internal, and not already covered by a resource list or the clients check.
    var visibleActions: [(name: String, action: Action)] {
        let used = Set((resources ?? []).flatMap { [$0.list, $0.create, $0.drop].compactMap { $0 } } + [clients].compactMap { $0 })
        return (actions ?? [:]).filter { $0.value.hidden != true && !used.contains($0.key) }
            .sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }
}

/// Runs a service's actions (e.g. Mailpit: recent/search/clear, Redis: keyspace/scan/flush).
struct ActionsPanel: View {
    @Environment(AppModel.self) private var model
    let service: ServiceView
    let actions: [(name: String, action: Recipe.Action)]
    @State private var values: [String: String] = [:]
    @State private var output = ""
    @State private var running: String?
    @State private var confirm: String?

    private static func isDestructive(_ name: String) -> Bool {
        ["clear", "flush", "drop", "delete", "restore"].contains { name.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(actions, id: \.name) { item in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.name.replacingOccurrences(of: "_", with: " ").capitalized).font(.callout.weight(.semibold))
                        Text(item.action.description).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    ForEach(item.action.params ?? [], id: \.self) { p in
                        TextField(p, text: Binding(get: { values["\(item.name).\(p)"] ?? "" },
                                                   set: { values["\(item.name).\(p)"] = $0 }))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 180)
                            .onSubmit { run(item.name) }
                    }
                    Button(running == item.name ? "Running…" : "Run") {
                        if Self.isDestructive(item.name) { confirm = item.name } else { run(item.name) }
                    }
                    .buttonStyle(.glass)
                    .tint(Self.isDestructive(item.name) ? .red : nil)
                    .disabled(running != nil)
                }
                .padding(.vertical, 2)
            }
            if !output.isEmpty {
                ScrollView {
                    Text(output).font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }
                .background(.background.secondary, in: .rect(cornerRadius: 10))
            } else {
                Spacer()
            }
        }
        .confirmationDialog("Run “\(confirm ?? "")” on \(service.name)? This can't be undone.",
                            isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            Button("Run", role: .destructive) { if let c = confirm { run(c) } }
        }
    }

    private func run(_ name: String) {
        let params = Dictionary(uniqueKeysWithValues: (actions.first { $0.name == name }?.action.params ?? []).map {
            ($0, values["\(name).\($0)"] ?? "")
        })
        running = name
        Task {
            defer { running = nil }
            do {
                let r: ServiceManager.ActionResult = try await model.api.post("services/\(service.id)/actions/\(name)",
                                                                              body: ActionRequest(params: params))
                output = r.output.isEmpty ? (r.ok ? "Done." : "Failed.") : r.output
            } catch { output = error.localizedDescription }
        }
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
                        let users = model.projectsUsing(service: service.id, kind: resources.id, name: item.name)
                        if !users.isEmpty {
                            Text("used by \(users.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
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
