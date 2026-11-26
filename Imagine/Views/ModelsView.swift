import SwiftUI
import UniformTypeIdentifiers

struct ModelsView: View {
    @EnvironmentObject var models: ModelStore
    @EnvironmentObject var gen: Generator
    @State private var showAdd = false
    @State private var showImporter = false
    @State private var confirmDelete: ModelInfo?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(String(format: "This iPhone has %.0f GB of memory", ModelStore.deviceRAMGB), systemImage: "memorychip")
                    Text("Models download once and then work offline. There's no content filter: the safety checker is never downloaded or used.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let err = models.lastError {
                    Section {
                        Label(err, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        Button("Dismiss") { models.lastError = nil }
                    }
                }
                Section("Models") {
                    ForEach(models.allModels) { m in
                        ModelRow(model: m, onDelete: { confirmDelete = m })
                    }
                }
                Section("Add your own") {
                    Button { showAdd = true } label: { Label("From Hugging Face or a link", systemImage: "plus.circle") }
                    Button { showImporter = true } label: { Label("Import from Files (.zip or folder)", systemImage: "folder.badge.plus") }
                    Text("Any Stable Diffusion model converted to Core ML works, e.g. from huggingface.co/coreml-community. Use \"split einsum\" versions for speed on the Neural Engine.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Performance") {
                    Picker("Run on", selection: $gen.computeUnits) {
                        Text("Auto (recommended)").tag("auto")
                        Text("Neural Engine").tag("ane")
                        Text("GPU").tag("gpu")
                        Text("All").tag("all")
                    }
                    Toggle("Reduce memory", isOn: $gen.reduceMemory)
                    Text("Turn on if the app closes while generating. A bit slower, much less memory. Always on for SDXL.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Live preview while generating", isOn: $gen.livePreview)
                }
                Section("About") {
                    Text("Imagine uses Apple's open-source ml-stable-diffusion (MIT). Models keep their own licenses (CreativeML OpenRAIL-M / SDXL).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Models")
            .sheet(isPresented: $showAdd) { AddModelView() }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.zip, .folder]) { result in
                if case .success(let url) = result { importLocal(url) }
            }
            .confirmationDialog("Delete this model?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), presenting: confirmDelete) { m in
                Button("Delete \(m.name)", role: .destructive) {
                    gen.unload()
                    models.delete(m)
                }
            }
        }
    }

    private func importLocal(_ url: URL) {
        let name = url.deletingPathExtension().lastPathComponent
        let m = ModelInfo(id: "custom-" + UUID().uuidString.prefix(8).lowercased(), name: name, details: "Imported from Files", source: .local, sizeMB: 0, isXL: false, attention: .splitEinsum, minRAMGB: 6, recommendedSteps: 25, isCustom: true)
        models.addCustom(m)
        Task {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                if url.pathExtension.lowercased() == "zip" {
                    try await models.install(zip: url, as: m, deleteZip: false)
                } else {
                    try await models.install(folder: url, as: m)
                }
            } catch {
                models.lastError = "\(name): \(error.localizedDescription)"
                models.delete(m)
            }
            models.finishImport(m)
        }
    }
}

struct ModelRow: View {
    let model: ModelInfo
    let onDelete: () -> Void
    @EnvironmentObject var models: ModelStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(model.name).font(.headline)
                if models.selectedModel?.id == model.id && installed {
                    Text("IN USE").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2).background(Color.accentColor.opacity(0.3), in: Capsule())
                }
            }
            Text(model.details).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Text(model.sizeMB > 0 ? ModelStore.mb(Int64(model.sizeMB) * 1_000_000) : "–")
                Text("needs \(model.minRAMGB) GB+ RAM").foregroundStyle(Double(model.minRAMGB) > ModelStore.deviceRAMGB + 0.5 ? .orange : .secondary)
                if model.isXL { Text("SDXL") }
            }
            .font(.caption2)
            if let d = models.downloads[model.id] {
                ProgressView(value: d.fraction)
                HStack {
                    Text(d.status).font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { models.cancel(model) }.font(.caption)
                }
                Text("Keep Imagine open until this finishes.").font(.caption2).foregroundStyle(.secondary)
            } else if installed {
                HStack {
                    Button("Use") { models.selectedID = model.id }.buttonStyle(.borderedProminent).disabled(models.selectedModel?.id == model.id)
                    Spacer()
                    Button("Delete", role: .destructive, action: onDelete).buttonStyle(.bordered)
                }
            } else if model.source != .local {
                Button { models.download(model) } label: { Label("Download", systemImage: "arrow.down.circle") }
                    .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }

    private var installed: Bool { models.installedRoots[model.id] != nil }
}

struct AddModelView: View {
    @EnvironmentObject var models: ModelStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [HFModelSummary] = []
    @State private var repo = ""
    @State private var candidates: [HuggingFace.Candidate] = []
    @State private var link = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Search Hugging Face Core ML models") {
                    HStack {
                        TextField("e.g. realistic, anime, dreamshaper", text: $query)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .onSubmit { search() }
                        Button("Search", action: search)
                    }
                    ForEach(results) { r in
                        Button { repo = r.id; loadRepo() } label: {
                            VStack(alignment: .leading) {
                                Text(r.id).font(.subheadline)
                                Text("\(r.downloads ?? 0) downloads").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("Or type a repo") {
                    TextField("owner/repo", text: $repo)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Show versions", action: loadRepo).disabled(repo.isEmpty)
                }
                if !candidates.isEmpty {
                    Section("Pick a version in \(repo)") {
                        ForEach(candidates) { c in
                            Button { add(c) } label: {
                                VStack(alignment: .leading) {
                                    Text(c.label).font(.subheadline)
                                    Text(c.kind == "zip" ? "Zip archive" : "Compiled folder").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                Section("Or paste a direct .zip link") {
                    TextField("https://…/model.zip", text: $link)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    Button("Download this zip") { addLink() }.disabled(URL(string: link)?.scheme?.hasPrefix("http") != true)
                }
                if busy { ProgressView() }
                if let error { Text(error).foregroundStyle(.orange).font(.footnote) }
            }
            .navigationTitle("Add model")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }

    private func search() {
        busy = true; error = nil
        Task {
            do { results = try await HuggingFace.search(query) } catch { self.error = error.localizedDescription }
            busy = false
        }
    }

    private func loadRepo() {
        let r = repo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !r.isEmpty else { return }
        busy = true; error = nil; candidates = []
        Task {
            do {
                candidates = try await HuggingFace.candidates(repo: r)
                if candidates.isEmpty { error = "No Core ML Stable Diffusion files found in this repo." }
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }

    private func add(_ c: HuggingFace.Candidate) {
        let r = repo.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = c.path.lowercased()
        let short = r.split(separator: "/").last.map(String.init) ?? r
        let variant = c.path.split(separator: "/").last.map(String.init) ?? ""
        let m = ModelInfo(
            id: "custom-" + UUID().uuidString.prefix(8).lowercased(),
            name: short.replacingOccurrences(of: "coreml-", with: ""),
            details: "\(r) · \(variant)",
            source: c.kind == "zip" ? .hfZip(repo: r, path: c.path) : .hfFolder(repo: r, path: c.path),
            sizeMB: c.sizeMB,
            isXL: lower.contains("xl"),
            attention: lower.contains("original") ? .original : .splitEinsum,
            minRAMGB: lower.contains("xl") ? 8 : 6,
            recommendedSteps: 25,
            isCustom: true)
        models.addCustom(m)
        models.download(m)
        dismiss()
    }

    private func addLink() {
        let name = URL(string: link)?.deletingPathExtension().lastPathComponent ?? "Custom model"
        let lower = link.lowercased()
        let m = ModelInfo(id: "custom-" + UUID().uuidString.prefix(8).lowercased(), name: name, details: link, source: .url(link), sizeMB: 0, isXL: lower.contains("xl"), attention: lower.contains("original") ? .original : .splitEinsum, minRAMGB: 6, recommendedSteps: 25, isCustom: true)
        models.addCustom(m)
        models.download(m)
        dismiss()
    }
}
