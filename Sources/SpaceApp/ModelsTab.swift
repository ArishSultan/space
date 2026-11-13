import SpaceCore
import SwiftUI

/// Ollama's models: download, turn on (loaded in memory) / off, delete, plus server settings.
struct ModelsTab: View {
    @Environment(AppModel.self) private var model
    let service: ServiceView
    @State private var models: [OllamaModel] = []
    @State private var pulls: [OllamaPull] = []
    @State private var settings = OllamaSettings()
    @State private var savedSettings = OllamaSettings()
    @State private var newModel = ""
    @State private var toggling: Set<String> = []
    @State private var deleting: OllamaModel?
    @State private var loadError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if service.isRunning {
                    Card("Download a model") {
                        HStack {
                            TextField("llama3.2, qwen2.5:7b, gemma3:4b …", text: $newModel)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit(pull)
                            Button("Download", systemImage: "arrow.down.circle", action: pull)
                                .buttonStyle(.glassProminent)
                                .disabled(newModel.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        ForEach(pulls) { p in PullRow(pull: p, cancel: { cancel(p) }) }
                    }
                    Card("Models") {
                        Text("On keeps a model loaded in memory, ready to answer instantly. Off frees the memory; the model stays downloaded and still loads on demand when something uses it.")
                            .font(.caption).foregroundStyle(.secondary)
                        if let loadError {
                            Text(loadError).font(.caption).foregroundStyle(.red)
                        } else if models.isEmpty {
                            Text("No models downloaded yet.").foregroundStyle(.secondary).padding(.vertical, 6)
                        }
                        ForEach(models) { m in
                            ModelRow(model: m, busy: toggling.contains(m.name),
                                     toggle: { setLoaded(m, $0) }, delete: { deleting = m })
                            if m.id != models.last?.id { Divider() }
                        }
                    }
                } else if let install = service.install, !install.installed {
                    ContentUnavailableView {
                        Label("Ollama isn't installed", systemImage: "arrow.down.circle")
                    } description: {
                        Text(install.brewAvailable ? "Space can install it with Homebrew."
                                                   : "Homebrew isn't installed. Download Ollama from its website; Space finds it automatically.")
                    } actions: {
                        HStack { InstallButtons(service: service, install: install) }
                    }
                } else {
                    ContentUnavailableView("Ollama is stopped", systemImage: "moon.zzz",
                                           description: Text("Start it to download and manage models."))
                }
                SettingsCard(settings: $settings, dirty: settings != savedSettings, running: service.isRunning, save: save)
            }
            .padding(18)
        }
        .confirmationDialog("Delete \(deleting?.name ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete from disk", role: .destructive) { if let m = deleting { delete(m) } }
        } message: {
            Text("The download is removed (\(Format.bytes(Double(deleting?.sizeBytes ?? 0)))). You can download it again later.")
        }
        .task { if let s: OllamaSettings = try? await model.api.get("ollama/settings") { settings = s; savedSettings = s } }
        .task(id: service.isRunning) {
            guard service.isRunning else { return }
            while !Task.isCancelled {
                await reload()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func reload() async {
        do {
            async let m: [OllamaModel] = model.api.get("ollama/models")
            async let p: [OllamaPull] = model.api.get("ollama/pulls")
            let (newModels, newPulls) = try await (m, p)
            // A finished download adds a model; show it without waiting for the next tick.
            models = newModels; pulls = newPulls; loadError = nil
        } catch { loadError = error.localizedDescription }
    }

    private func post(_ path: String, _ name: String) async throws {
        try await model.api.post(path, body: OllamaNameRequest(name: name), as: OK.self)
    }

    private func pull() {
        let name = newModel.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        newModel = ""
        Task {
            do { try await post("ollama/models/pull", name) } catch { model.lastError = error.localizedDescription }
            await reload()
        }
    }

    private func cancel(_ p: OllamaPull) {
        Task { try? await post("ollama/pulls/cancel", p.name); await reload() }
    }

    private func setLoaded(_ m: OllamaModel, _ on: Bool) {
        toggling.insert(m.name)
        Task {
            defer { toggling.remove(m.name) }
            do { try await post(on ? "ollama/models/load" : "ollama/models/unload", m.name) }
            catch { model.lastError = error.localizedDescription }
            await reload()
        }
    }

    private func delete(_ m: OllamaModel) {
        Task {
            do { let _: OK = try await model.api.call("DELETE", "ollama/models", query: ["name": m.name]) }
            catch { model.lastError = error.localizedDescription }
            await reload()
        }
    }

    private func save() {
        Task {
            do {
                let saved: OllamaSettings = try await model.api.post("ollama/settings", body: settings)
                settings = saved; savedSettings = saved
                if service.isRunning { model.restart(service.id, origin: service.id) }
            } catch { model.lastError = error.localizedDescription }
        }
    }
}

private struct ModelRow: View {
    let model: OllamaModel
    let busy: Bool
    let toggle: (Bool) -> Void
    let delete: () -> Void

    private var detail: String {
        [model.parameterSize, model.quantization, Format.bytes(Double(model.sizeBytes))].compactMap { $0 }.joined(separator: " · ")
    }

    private var status: (text: String, color: Color)? {
        if let e = model.error { return ("Couldn't load: \(e)", .red) }
        if model.loading { return ("Loading into memory…", .secondary) }
        if model.pinned { return ("In memory, kept until you turn it off · \(Format.bytes(Double(model.memoryBytes ?? 0)))", .green) }
        if model.loaded {
            let when = model.expiresAt.map { " · unloads \($0.formatted(.relative(presentation: .numeric)))" } ?? ""
            return ("In memory\(when)", .green)
        }
        return nil
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.name).font(.callout.weight(.semibold)).textSelection(.enabled)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                if let status { Text(status.text).font(.caption).foregroundStyle(status.color).lineLimit(2) }
            }
            Spacer()
            if model.loading || busy { ProgressView().controlSize(.small) }
            Toggle("", isOn: Binding(get: { model.loaded || model.loading }, set: toggle))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(busy)
                .help(model.loaded ? "Unload from memory" : "Load into memory and keep it there")
            Button("Delete", systemImage: "trash", action: delete)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Delete the download")
        }
        .padding(.vertical, 2)
    }
}

private struct PullRow: View {
    let pull: OllamaPull
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(pull.name).font(.callout.weight(.semibold))
                Spacer()
                if !pull.done { Button("Cancel", action: cancel).buttonStyle(.borderless).font(.caption) }
            }
            if let error = pull.error {
                Text(error).font(.caption).foregroundStyle(.red)
            } else if pull.done {
                Text(pull.status == "success" ? "Downloaded" : pull.status.capitalized).font(.caption).foregroundStyle(.secondary)
            } else {
                if let f = pull.fraction { ProgressView(value: f) } else { ProgressView().progressViewStyle(.linear) }
                Text(pull.totalBytes > 0 ? "\(Format.bytes(Double(pull.completedBytes))) of \(Format.bytes(Double(pull.totalBytes)))" : pull.status)
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }
}

private struct SettingsCard: View {
    @Binding var settings: OllamaSettings
    let dirty: Bool
    let running: Bool
    let save: () -> Void

    private static let keepAlives: [(String, String)] = [("", "Default (5 min)"), ("1m", "1 minute"), ("5m", "5 minutes"), ("30m", "30 minutes"),
                                                         ("1h", "1 hour"), ("24h", "24 hours"), ("-1", "Forever")]

    private func intBinding(_ path: WritableKeyPath<OllamaSettings, Int?>) -> Binding<Int> {
        Binding(get: { settings[keyPath: path] ?? 0 }, set: { settings[keyPath: path] = $0 == 0 ? nil : $0 })
    }

    var body: some View {
        Card("Server settings") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Text("Models in memory at once")
                    Picker("", selection: intBinding(\.maxLoadedModels)) {
                        Text("Default").tag(0)
                        ForEach([1, 2, 3, 4, 6, 8], id: \.self) { Text("\($0)").tag($0) }
                    }.labelsHidden().fixedSize()
                }
                GridRow {
                    Text("Unload an idle model after")
                    Picker("", selection: Binding(get: { settings.keepAlive ?? "" }, set: { settings.keepAlive = $0.isEmpty ? nil : $0 })) {
                        ForEach(Self.keepAlives, id: \.0) { Text($0.1).tag($0.0) }
                        if let k = settings.keepAlive, !Self.keepAlives.contains(where: { $0.0 == k }) { Text(k).tag(k) }
                    }.labelsHidden().fixedSize()
                }
                GridRow {
                    Text("Parallel requests per model")
                    Picker("", selection: intBinding(\.numParallel)) {
                        Text("Default").tag(0)
                        ForEach([1, 2, 4, 8], id: \.self) { Text("\($0)").tag($0) }
                    }.labelsHidden().fixedSize()
                }
            }
            HStack {
                Button(running ? "Save and restart Ollama" : "Save", systemImage: "checkmark.circle", action: save)
                    .buttonStyle(.glassProminent)
                    .disabled(!dirty)
                if dirty && running {
                    Text("Restarting unloads models; pinned ones load again afterwards.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
