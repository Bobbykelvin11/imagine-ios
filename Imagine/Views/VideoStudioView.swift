import SwiftUI
import PhotosUI

struct VideoStudioView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var engine: OnlineEngine
    @EnvironmentObject var gallery: GalleryStore

    @AppStorage("videoPrompt") private var prompt = ""
    @AppStorage("videoAspect") private var aspectRaw = AspectRatio.tall.rawValue
    @AppStorage("videoSeconds") private var seconds = 3.0
    @State private var photo: UIImage?
    @State private var pickerItem: PhotosPickerItem?

    @State private var clipStyle: ClipMaker.Style = .kenBurns
    @State private var clipSeconds = 3.0
    @State private var clipPicks: [PhotosPickerItem] = []
    @State private var clipImages: [UIImage] = []
    @State private var selectedGallery: Set<UUID> = []
    @State private var detail: GalleryItem?

    private var aspect: AspectRatio { AspectRatio(rawValue: aspectRaw) ?? .tall }
    private var videoJobs: [Job] { engine.jobs.filter { $0.kind == .video } }
    private var recentVideos: [GalleryItem] { Array(gallery.items.filter { $0.kind == .video }.prefix(12)) }
    private var galleryImages: [GalleryItem] { Array(gallery.items.filter { $0.kind == .image }.prefix(30)) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Describe the motion or scene…", text: $prompt, axis: .vertical).lineLimit(2...5)
                    HStack {
                        if let photo {
                            Image(uiImage: photo).resizable().scaledToFill().frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 8))
                            Text("Animate this photo").font(.subheadline)
                            Spacer()
                            Button(role: .destructive) { self.photo = nil } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless)
                        } else {
                            PhotosPicker(selection: $pickerItem, matching: .images) { Label("Start from a photo (optional)", systemImage: "photo") }
                        }
                    }
                    Picker("Shape", selection: $aspectRaw) {
                        ForEach([AspectRatio.tall, .wide, .square, .photo, .photoWide]) { Text($0.rawValue).tag($0.rawValue) }
                    }
                    .disabled(photo != nil)
                    Picker("Length", selection: $seconds) { ForEach([2.0, 3.0, 4.0, 5.0], id: \.self) { Text("\(Int($0)) s").tag($0) } }
                    Picker("Engine", selection: $engine.videoEngine) { ForEach(VideoEngine.allCases) { Text($0.title).tag($0) } }
                    Button {
                        engine.generateVideo(prompt: prompt, aspect: photo.map(aspectOf) ?? aspect, from: photo, duration: seconds)
                    } label: {
                        Label("Make AI video", systemImage: "sparkles").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(prompt.trimmingCharacters(in: .whitespaces).isEmpty && photo == nil)
                } header: {
                    Text("AI video · free online")
                } footer: {
                    Text("Runs the open-source LTX-2.3 model (with sound) on free Hugging Face GPUs. A clip usually takes 25 to 60 seconds. Free GPU time is limited per day: about 2 minutes without an account, 5 minutes with a free Hugging Face token (Settings). No open video model is small enough to run on an iPhone itself.")
                }

                if !videoJobs.isEmpty {
                    Section("Working on") {
                        ForEach(videoJobs) { job in JobTile(job: job).frame(maxHeight: 260) }
                    }
                }

                Section {
                    if !galleryImages.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(galleryImages) { item in
                                    Button { toggle(item) } label: {
                                        FeedTile(item: item).frame(width: 74, height: 74)
                                            .overlay(alignment: .topTrailing) {
                                                if let i = order(of: item) {
                                                    Text("\(i)").font(.caption2.bold()).padding(5).background(accentPurple, in: Circle()).padding(3)
                                                }
                                            }
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    PhotosPicker(selection: $clipPicks, maxSelectionCount: 10, matching: .images) {
                        Label(clipImages.isEmpty ? "Or pick photos from your library" : "\(clipImages.count) photos picked", systemImage: "photo.stack")
                    }
                    Picker("Style", selection: $clipStyle) { ForEach(ClipMaker.Style.allCases) { Text($0.rawValue).tag($0) } }
                    Stepper("\(Int(clipSeconds)) s per picture", value: $clipSeconds, in: 2...8)
                    Button {
                        engine.makeClip(from: clipSources(), prompt: prompt, style: clipStyle, seconds: clipSeconds)
                        selectedGallery = []; galleryOrder = []; clipImages = []; clipPicks = []
                    } label: { Label("Make clip on iPhone", systemImage: "film").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
                    .disabled(clipSources().isEmpty)
                } header: {
                    Text("On-device clip · unlimited, offline")
                } footer: {
                    Text("Turns your pictures into an MP4 with slow zoom and pan, or morphs from one picture into the next. Tip: make 4 images of one prompt, select them in order, and choose Morph.")
                }

                if !recentVideos.isEmpty {
                    Section("Recent videos") {
                        ForEach(recentVideos) { item in
                            Button { detail = item } label: {
                                HStack {
                                    FeedTile(item: item).frame(width: 60, height: 60)
                                    VStack(alignment: .leading) {
                                        Text(item.prompt).lineLimit(2).font(.subheadline)
                                        Text(item.model).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("Video")
            .sheet(item: $detail) { item in NavigationStack { GalleryDetailView(item: item) } }
            .onAppear { takeHandoff() }
            .onChange(of: app.videoImage) { _, _ in takeHandoff() }
            .onChange(of: pickerItem) { _, item in
                Task {
                    if let d = try? await item?.loadTransferable(type: Data.self), let img = UIImage(data: d) { photo = img }
                    pickerItem = nil
                }
            }
            .onChange(of: clipPicks) { _, items in
                Task {
                    var out: [UIImage] = []
                    for i in items { if let d = try? await i.loadTransferable(type: Data.self), let img = UIImage(data: d) { out.append(img) } }
                    clipImages = out
                }
            }
        }
    }

    @State private var galleryOrder: [UUID] = []

    private func toggle(_ item: GalleryItem) {
        if let i = galleryOrder.firstIndex(of: item.id) { galleryOrder.remove(at: i); selectedGallery.remove(item.id) }
        else { galleryOrder.append(item.id); selectedGallery.insert(item.id) }
    }

    private func order(of item: GalleryItem) -> Int? {
        guard selectedGallery.contains(item.id) else { return nil }
        return galleryOrder.firstIndex(of: item.id).map { $0 + 1 }
    }

    private func clipSources() -> [UIImage] {
        let fromGallery = galleryOrder.filter { selectedGallery.contains($0) }.compactMap { id in
            gallery.items.first { $0.id == id }.flatMap { gallery.image($0) }
        }
        return fromGallery + clipImages
    }

    private func takeHandoff() {
        if let img = app.videoImage { photo = img; app.videoImage = nil }
    }
}
