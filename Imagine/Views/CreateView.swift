import SwiftUI
import PhotosUI

struct StylePreset: Identifiable {
    let id: String
    let suffix: String
}

let stylePresets: [StylePreset] = [
    StylePreset(id: "Photo", suffix: "photorealistic, 85mm photo, sharp focus, natural light, highly detailed"),
    StylePreset(id: "Cinematic", suffix: "cinematic still, dramatic lighting, film grain, shallow depth of field"),
    StylePreset(id: "Pet portrait", suffix: "adorable pet portrait, detailed fur, studio lighting, bokeh background"),
    StylePreset(id: "Anime", suffix: "anime style, vibrant colors, clean line art, detailed"),
    StylePreset(id: "3D render", suffix: "3d render, octane render, soft lighting, high detail"),
    StylePreset(id: "Oil painting", suffix: "oil painting, visible brush strokes, rich colors, masterpiece"),
    StylePreset(id: "Fantasy", suffix: "epic fantasy art, intricate details, glowing light, concept art")
]

struct CreateView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var models: ModelStore
    @EnvironmentObject var gen: Generator

    @AppStorage("prompt") private var prompt = ""
    @AppStorage("negative") private var negative = "blurry, lowres, bad anatomy, extra fingers, deformed, watermark, text"
    @AppStorage("steps") private var steps = 20.0
    @AppStorage("guidance") private var guidance = 7.5
    @AppStorage("imageCount") private var imageCount = 1
    @AppStorage("scheduler") private var scheduler = "dpm"
    @AppStorage("lockSeed") private var lockSeed = false
    @AppStorage("seed") private var seedValue = 42
    @State private var strength = 0.6
    @State private var pickerItem: PhotosPickerItem?
    @State private var style: String?
    @State private var showAdvanced = false
    @State private var detail: GalleryItem?
    @State private var showModels = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if models.installedModels.isEmpty {
                        noModelCard
                    } else {
                        modelPicker
                    }
                    promptBox
                    styleChips
                    startImageRow
                    settingsCard
                    generateButton
                    statusView
                    resultsView
                }
                .padding()
            }
            .navigationTitle("Offline")
            .sheet(isPresented: $showModels) { ModelsView() }
            .scrollDismissesKeyboard(.interactively)
            .sheet(item: $detail) { item in
                NavigationStack { GalleryDetailView(item: item) }
            }
            .onChange(of: pickerItem) { _, item in
                Task {
                    if let data = try? await item?.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                        app.startImage = img
                    }
                }
            }
            .onChange(of: app.reuse) { _, item in
                guard let item else { return }
                prompt = item.prompt
                negative = item.negativePrompt
                if item.steps > 0 { steps = Double(item.steps) }
                if item.guidance > 0 { guidance = Double(item.guidance) }
                seedValue = Int(item.seed)
                lockSeed = true
                app.reuse = nil
            }
            .onChange(of: models.selectedID) { _, _ in
                if let m = models.selectedModel { steps = Double(m.recommendedSteps) }
            }
        }
    }

    private var noModelCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Download a model to start", systemImage: "arrow.down.circle.fill").font(.headline)
            Text("Images are made fully on your iPhone, offline and without filters. Get a model once from the Models tab; Stable Diffusion 2.1 (1.1 GB) is the quickest to start with.")
                .font(.subheadline).foregroundStyle(.secondary)
            Button("Open Models") { showModels = true }.buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var modelPicker: some View {
        Menu {
            ForEach(models.installedModels) { m in
                Button { models.selectedID = m.id } label: {
                    if m.id == models.selectedModel?.id { Label(m.name, systemImage: "checkmark") } else { Text(m.name) }
                }
            }
        } label: {
            HStack {
                Image(systemName: "cpu")
                Text(models.selectedModel?.name ?? "Pick a model").lineLimit(1)
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.caption)
            }
            .padding(12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .disabled(gen.isBusy)
    }

    private var promptBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                if prompt.isEmpty {
                    Text("Describe your image… e.g. a golden retriever puppy wearing sunglasses on a beach at sunset")
                        .foregroundStyle(.secondary).padding(.horizontal, 5).padding(.vertical, 8)
                }
                TextEditor(text: $prompt)
                    .frame(minHeight: 90)
                    .scrollContentBackground(.hidden)
            }
            .padding(8)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            DisclosureGroup("Negative prompt (what to avoid)") {
                TextField("Things to leave out", text: $negative, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
            }
            .font(.subheadline)
        }
    }

    private var styleChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(stylePresets) { s in
                    Button(s.id) { style = (style == s.id) ? nil : s.id }
                        .buttonStyle(.bordered)
                        .tint(style == s.id ? .accentColor : .gray)
                }
            }
        }
    }

    private var startImageRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Label(app.startImage == nil ? "Start from a photo" : "Change photo", systemImage: "photo.badge.plus")
                }
                .buttonStyle(.bordered)
                if app.startImage != nil {
                    Button(role: .destructive) { app.startImage = nil; pickerItem = nil } label: { Image(systemName: "xmark.circle") }
                }
                Spacer()
            }
            if let img = app.startImage {
                HStack(alignment: .top) {
                    Image(uiImage: img).resizable().scaledToFill().frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading) {
                        Text("Change amount: \(Int(strength * 100))%").font(.subheadline)
                        Slider(value: $strength, in: 0.1...0.95)
                        Text("Low keeps your photo, high changes more.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let root = currentRoot, !ModelStore.hasEncoder(root: root) {
                    Text("This model can't start from a photo; it will make a new image instead.").font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    private var settingsCard: some View {
        DisclosureGroup(isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading) {
                    Text("Steps: \(Int(steps))  ·  more = more detail, slower")
                    Slider(value: $steps, in: 4...50, step: 1)
                }
                VStack(alignment: .leading) {
                    Text(String(format: "Prompt strength (guidance): %.1f", guidance))
                    Slider(value: $guidance, in: 1...15, step: 0.5)
                }
                Stepper("Images per run: \(imageCount)", value: $imageCount, in: 1...4)
                Picker("Sampler", selection: $scheduler) {
                    Text("DPM++ (fast, sharp)").tag("dpm")
                    Text("PNDM (classic)").tag("pndm")
                }
                Toggle("Keep the same seed", isOn: $lockSeed)
                if lockSeed {
                    HStack {
                        Text("Seed")
                        TextField("Seed", value: $seedValue, format: .number.grouping(.never))
                            .keyboardType(.numberPad)
                            .textFieldStyle(.roundedBorder)
                        Button { seedValue = Int.random(in: 0...Int(UInt32.max)) } label: { Image(systemName: "dice") }
                    }
                }
                if let root = currentRoot, let size = ModelStore.outputSize(root: root) {
                    Text("Image size: \(Int(size.width))×\(Int(size.height)) (set by the model)").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 8)
        } label: {
            Label("Settings", systemImage: "slider.horizontal.3")
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var currentRoot: URL? {
        guard let m = models.selectedModel else { return nil }
        return models.installedRoots[m.id]
    }

    private var fullPrompt: String {
        let base = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let style, let preset = stylePresets.first(where: { $0.id == style }) else { return base }
        return base.isEmpty ? preset.suffix : base + ", " + preset.suffix
    }

    private var generateButton: some View {
        Group {
            if gen.isBusy {
                Button(role: .destructive) { gen.cancel() } label: {
                    Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
            } else {
                Button {
                    hideKeyboard()
                    guard let m = models.selectedModel, let root = models.installedRoots[m.id] else { return }
                    let seed: UInt32 = lockSeed ? UInt32(clamping: seedValue) : UInt32.random(in: 0...UInt32.max)
                    if !lockSeed { seedValue = Int(seed) }
                    let p = GenParams(prompt: fullPrompt, negativePrompt: negative, steps: Int(steps), guidance: Float(guidance), seed: seed, imageCount: imageCount, scheduler: scheduler, startImage: app.startImage, strength: Float(strength))
                    gen.generate(p, model: m, root: root)
                } label: {
                    Label("Generate", systemImage: "sparkles").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(models.selectedModel == nil || fullPrompt.isEmpty)
            }
        }
    }

    @ViewBuilder private var statusView: some View {
        switch gen.phase {
        case .idle:
            if !gen.results.isEmpty {
                Text(String(format: "Done in %.0f s", gen.lastDuration)).font(.caption).foregroundStyle(.secondary)
            }
        case .loading(let msg):
            HStack(alignment: .top) { ProgressView(); Text(msg).font(.subheadline) }
        case .running(let step, let total):
            VStack(alignment: .leading) {
                ProgressView(value: Double(step), total: Double(max(total, 1)))
                Text("Step \(step) of \(total)").font(.caption).foregroundStyle(.secondary)
            }
        case .error(let msg):
            Label(msg, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.subheadline)
        }
        if let pv = gen.preview {
            Image(uiImage: pv).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 14)).opacity(0.85)
        }
    }

    private var resultsView: some View {
        LazyVGrid(columns: gen.results.count == 1 ? [GridItem(.flexible())] : [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(gen.results) { item in
                Button { detail = item } label: {
                    if let img = GalleryStore.shared.image(item) {
                        Image(uiImage: img).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                }
            }
        }
    }
}

func hideKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}
