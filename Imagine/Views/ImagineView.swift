import SwiftUI
import PhotosUI
import AVFoundation

let accentPurple = Color(red: 0.62, green: 0.45, blue: 1.0)

struct ImagineView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var engine: OnlineEngine
    @EnvironmentObject var gallery: GalleryStore

    enum Mode: String, CaseIterable { case image = "Image", video = "Video" }

    @AppStorage("onlinePrompt") private var prompt = ""
    @AppStorage("onlineAspect") private var aspectRaw = AspectRatio.portrait.rawValue
    @AppStorage("videoSeconds") private var videoSeconds = 3.0
    @State private var mode: Mode = .image
    @State private var attached: UIImage?
    @State private var pickerItem: PhotosPickerItem?
    @State private var detail: GalleryItem?
    @State private var lastPrompt = ""
    @FocusState private var focused: Bool

    private var aspect: AspectRatio { AspectRatio(rawValue: aspectRaw) ?? .portrait }
    private var feedItems: [GalleryItem] { gallery.items }

    var body: some View {
        NavigationStack {
            ScrollView {
                if engine.jobs.isEmpty && feedItems.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                        ForEach(engine.jobs) { job in
                            JobTile(job: job)
                        }
                        ForEach(feedItems) { item in
                            Button { detail = item } label: { FeedTile(item: item) }
                                .buttonStyle(.plain)
                                .onAppear { loadMoreIfNeeded(item) }
                                .contextMenu { tileMenu(item) }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.top, 4)
                    if let p = (lastPrompt.isEmpty ? feedItems.first?.prompt : lastPrompt), !p.isEmpty {
                        Button { engine.generateImages(prompt: p, aspect: aspect) } label: {
                            Label("More like \"\(p.prefix(40))\"", systemImage: "sparkles").font(.footnote)
                        }
                        .buttonStyle(.bordered).padding(.vertical, 14)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Imagine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("Image engine", selection: $engine.imageEngine) {
                            ForEach(ImageEngine.allCases) { Text($0.title).tag($0) }
                        }
                        Picker("Video engine", selection: $engine.videoEngine) {
                            ForEach(VideoEngine.allCases) { Text($0.title).tag($0) }
                        }
                    } label: { Image(systemName: "cpu") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Toggle(isOn: $engine.endless) { Image(systemName: "infinity") }
                        .toggleStyle(.button)
                        .accessibilityLabel("Endless feed")
                }
            }
            .safeAreaInset(edge: .bottom) { promptBar }
            .sheet(item: $detail) { item in NavigationStack { GalleryDetailView(item: item) } }
            .onChange(of: pickerItem) { _, item in
                Task {
                    if let data = try? await item?.loadTransferable(type: Data.self), let img = UIImage(data: data) { attached = img }
                    pickerItem = nil
                }
            }
            .onChange(of: app.editImage) { _, img in
                guard let img else { return }
                attached = img; mode = .image; app.editImage = nil; focused = true
            }
            .onChange(of: app.remixPrompt) { _, p in
                guard let p else { return }
                prompt = p; app.remixPrompt = nil; send()
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles").font(.system(size: 44)).foregroundStyle(accentPurple)
            Text("Type anything to imagine it").font(.title3.bold())
            Text("Free online AI: Z-Image, FLUX and LTX video on Hugging Face, with Pollinations and AI Horde as backups. No account or payment needed.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(["a golden retriever surfing a big wave, action photo",
                         "portrait of a woman in a neon-lit Tokyo street at night, 35mm film",
                         "a cozy cabin in snowy mountains at sunrise, ultra realistic"], id: \.self) { s in
                    Button { prompt = s; send() } label: {
                        Text(s).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10).background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(.plain)
                }
            }
        }
        .padding(28)
        .padding(.top, 40)
    }

    private var promptBar: some View {
        VStack(spacing: 8) {
            if let attached {
                HStack(spacing: 10) {
                    Image(uiImage: attached).resizable().scaledToFill().frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 8))
                    Text(mode == .image ? "Editing this photo. Describe the change." : "Animating this photo.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { self.attached = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                }
                .padding(.horizontal, 4)
            }
            HStack(spacing: 8) {
                Picker("Mode", selection: $mode) { ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).frame(width: 140)
                Menu {
                    Picker("Aspect ratio", selection: $aspectRaw) {
                        ForEach(AspectRatio.allCases) { Text($0.rawValue).tag($0.rawValue) }
                    }
                } label: { chip(aspect.rawValue, icon: "aspectratio") }
                if mode == .image {
                    Menu {
                        Picker("Images", selection: $engine.imagesPerPrompt) { ForEach(1...4, id: \.self) { Text("\($0) image\($0 > 1 ? "s" : "")").tag($0) } }
                    } label: { chip("×\(engine.imagesPerPrompt)", icon: "square.grid.2x2") }
                } else {
                    Menu {
                        Picker("Length", selection: $videoSeconds) { ForEach([2.0, 3.0, 4.0, 5.0], id: \.self) { Text("\(Int($0)) seconds").tag($0) } }
                    } label: { chip("\(Int(videoSeconds))s", icon: "timer") }
                }
                Spacer(minLength: 0)
            }
            HStack(alignment: .bottom, spacing: 8) {
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Image(systemName: "photo.badge.plus").font(.title3).frame(width: 38, height: 38)
                        .background(Color.white.opacity(0.08), in: Circle())
                }
                TextField(mode == .image ? "Imagine anything…" : "Describe the video…", text: $prompt, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($focused)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 20))
                    .submitLabel(.send)
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "arrow.up").font(.headline.bold()).foregroundStyle(.black)
                        .frame(width: 38, height: 38)
                        .background(canSend ? Color.white : Color.white.opacity(0.3), in: Circle())
                }
                .disabled(!canSend)
            }
        }
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)
        .background(.ultraThinMaterial)
    }

    private var canSend: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (mode == .video && attached != nil)
    }

    private func chip(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon).font(.caption.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color.white.opacity(0.08), in: Capsule())
    }

    private func send() {
        guard canSend else { return }
        focused = false
        lastPrompt = prompt
        switch mode {
        case .image: engine.generateImages(prompt: prompt, aspect: aspect, editing: attached)
        case .video: engine.generateVideo(prompt: prompt, aspect: aspect, from: attached, duration: videoSeconds)
        }
        if mode == .image && attached != nil { attached = nil }
    }

    /// Endless mode: reaching the bottom of the feed makes more of the last prompt.
    private func loadMoreIfNeeded(_ item: GalleryItem) {
        guard engine.endless, engine.runningCount == 0, item.id == feedItems.last?.id else { return }
        let p = lastPrompt.isEmpty ? (feedItems.first?.prompt ?? "") : lastPrompt
        guard !p.isEmpty else { return }
        engine.generateImages(prompt: p, aspect: aspect)
    }

    @ViewBuilder private func tileMenu(_ item: GalleryItem) -> some View {
        if item.kind == .image, let img = gallery.image(item) {
            Button { engine.generateVideo(prompt: item.prompt, aspect: aspectOf(img), from: img, duration: videoSeconds) } label: { Label("Make video", systemImage: "film") }
            Button { attached = img; mode = .image; focused = true } label: { Label("Edit", systemImage: "wand.and.stars") }
        }
        Button { prompt = item.prompt; send() } label: { Label("More like this", systemImage: "arrow.triangle.2.circlepath") }
        Button { OnlineEngine.saveToPhotos(item) } label: { Label("Save to Photos", systemImage: "square.and.arrow.down") }
        Button(role: .destructive) { gallery.delete(item) } label: { Label("Delete", systemImage: "trash") }
    }
}

func aspectOf(_ img: UIImage) -> AspectRatio {
    let r = img.size.width / max(img.size.height, 1)
    return AspectRatio.allCases.min { abs($0.ratio - r) < abs($1.ratio - r) } ?? .square
}

struct JobTile: View {
    let job: Job
    @EnvironmentObject var engine: OnlineEngine

    var body: some View {
        ZStack {
            if let p = job.preview {
                Image(uiImage: p).resizable().scaledToFill().blur(radius: 14).opacity(0.5)
            }
            LinearGradient(colors: [accentPurple.opacity(0.35), .black.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing)
                .opacity(job.preview == nil ? 1 : 0.4)
            VStack(spacing: 8) {
                switch job.state {
                case .running:
                    ProgressView().tint(.white)
                    TimelineView(.periodic(from: job.started, by: 1)) { ctx in
                        Text("\(Int(ctx.date.timeIntervalSince(job.started)))s").font(.caption.monospacedDigit().bold())
                    }
                    Text(job.status).font(.caption2).multilineTextAlignment(.center).foregroundStyle(.secondary).lineLimit(3)
                    Button("Cancel") { engine.cancel(job.id) }.font(.caption2).buttonStyle(.bordered)
                case .failed(let msg):
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    ScrollView { Text(msg).font(.caption2).multilineTextAlignment(.center) }.frame(maxHeight: 120)
                    Button("Dismiss") { engine.dismiss(job.id) }.font(.caption2).buttonStyle(.bordered)
                case .done:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Label(job.kind == .video ? "Video" : "Image", systemImage: job.kind == .video ? "film" : "photo").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(10)
        }
        .aspectRatio(job.aspect.ratio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

struct FeedTile: View {
    let item: GalleryItem
    @State private var thumb: UIImage?

    var body: some View {
        Color.white.opacity(0.06)
            .aspectRatio(ratio, contentMode: .fit)
            .overlay {
                if let thumb { Image(uiImage: thumb).resizable().scaledToFill() }
            }
            .overlay(alignment: .topTrailing) {
                if item.kind == .video {
                    Image(systemName: "play.fill").font(.caption).padding(6).background(.black.opacity(0.5), in: Circle()).padding(6)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .contentShape(Rectangle())
            .task(id: item.id) { thumb = await ThumbCache.shared.thumb(for: item) }
    }

    private var ratio: CGFloat {
        guard let t = thumb, t.size.height > 0 else { return 0.75 }
        return max(0.5, min(1.8, t.size.width / t.size.height))
    }
}

/// Small in-memory thumbnails so the feed scrolls smoothly.
actor ThumbCache {
    static let shared = ThumbCache()
    private var cache: [UUID: UIImage] = [:]

    func thumb(for item: GalleryItem) async -> UIImage? {
        if let c = cache[item.id] { return c }
        let url = await MainActor.run { GalleryStore.shared.url(item) }
        var img: UIImage?
        if item.kind == .image {
            if let full = UIImage(contentsOfFile: url.path) { img = await full.byPreparingThumbnail(ofSize: Self.fit(full.size, 600)) ?? full }
        } else {
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 600, height: 600)
            if let cg = try? await gen.image(at: .zero).image { img = UIImage(cgImage: cg) }
        }
        if let img { cache[item.id] = img }
        return img
    }

    static func fit(_ s: CGSize, _ m: CGFloat) -> CGSize {
        let k = min(1, m / max(s.width, s.height))
        return CGSize(width: s.width * k, height: s.height * k)
    }
}
