import SwiftUI
import PhotosUI
import AVKit

struct VideoView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var video: VideoService
    @AppStorage("videoPrompt") private var prompt = ""
    @AppStorage("videoNegative") private var negative = ""
    @AppStorage("videoModel") private var modelID = VideoCatalog.models[0].id
    @AppStorage("videoResolution") private var resolution = "480p"
    @State private var pickerItem: PhotosPickerItem?
    @State private var showKey = false
    @State private var detail: GalleryItem?

    private var selected: VideoModel? { VideoCatalog.models.first { $0.id == modelID } }
    private var effectiveModel: String {
        let c = video.customModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        return c.isEmpty ? modelID : c
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("iPhones can't make AI video on the phone itself yet; it needs a big GPU. This tab sends your prompt to open-source video models (Wan 2.2, LTX-Video) on fal.ai with your own key, so you pay fal.ai per clip (about $0.10–$0.40). Images in the Create tab stay 100% on your phone.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("fal.ai key") {
                    if video.apiKey.isEmpty || showKey {
                        SecureField("Paste your fal.ai API key", text: $video.apiKey)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Link("Get a key at fal.ai/dashboard/keys", destination: URL(string: "https://fal.ai/dashboard/keys")!)
                    } else {
                        HStack {
                            Label("Key saved in Keychain", systemImage: "key.fill")
                            Spacer()
                            Button("Change") { showKey = true }
                        }
                    }
                }
                Section("Model") {
                    Picker("Video model", selection: $modelID) {
                        ForEach(VideoCatalog.models) { m in Text(m.name).tag(m.id) }
                    }
                    if let s = selected { Text(s.details).font(.caption).foregroundStyle(.secondary) }
                    Picker("Quality", selection: $resolution) {
                        Text("480p (cheaper)").tag("480p")
                        Text("720p").tag("720p")
                    }
                    TextField("Other fal.ai model id (optional)", text: $video.customModelID)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().font(.caption)
                }
                Section("Prompt") {
                    TextField("e.g. a kitten chasing a butterfly in a sunny garden, slow motion", text: $prompt, axis: .vertical)
                        .lineLimit(3...6)
                    TextField("Avoid (optional)", text: $negative, axis: .vertical)
                }
                Section("Start image") {
                    if let img = app.videoImage {
                        HStack {
                            Image(uiImage: img).resizable().scaledToFill().frame(width: 80, height: 80).clipShape(RoundedRectangle(cornerRadius: 10))
                            Spacer()
                            Button("Remove", role: .destructive) { app.videoImage = nil; pickerItem = nil }
                        }
                    }
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Label(app.videoImage == nil ? "Pick a photo to animate" : "Change photo", systemImage: "photo")
                    }
                    if selected?.needsImage == true && app.videoImage == nil {
                        Text("This model needs a start image. Pick one, or tap Animate on an image in the Gallery.").font(.caption).foregroundStyle(.orange)
                    }
                    if selected?.needsImage == false && app.videoImage != nil {
                        Text("Tip: switch to \"Wan 2.2 animate an image\" to use this photo.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    if video.isRunning {
                        HStack { ProgressView(); Text(video.status) }
                        Button("Cancel", role: .destructive) { video.cancel() }
                    } else {
                        Button {
                            hideKeyboard()
                            let img = (selected?.needsImage ?? false) || !video.customModelID.isEmpty ? app.videoImage : nil
                            video.generate(modelID: effectiveModel, prompt: prompt, negative: negative, image: img, resolution: resolution)
                        } label: {
                            Label("Make video", systemImage: "film.stack").font(.headline)
                        }
                        .disabled(prompt.trimmingCharacters(in: .whitespaces).isEmpty || video.apiKey.isEmpty || (selected?.needsImage == true && app.videoImage == nil && video.customModelID.isEmpty))
                    }
                    if let e = video.error {
                        Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.footnote)
                    }
                }
                if let v = video.lastVideo {
                    Section("Latest video") {
                        VideoPlayer(player: AVPlayer(url: GalleryStore.shared.url(v))).frame(height: 300)
                        Button("Open in Gallery") { detail = v }
                    }
                }
            }
            .navigationTitle("Video")
            .sheet(item: $detail) { item in NavigationStack { GalleryDetailView(item: item) } }
            .onChange(of: pickerItem) { _, item in
                Task {
                    if let data = try? await item?.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                        app.videoImage = img
                    }
                }
            }
            .onChange(of: app.videoImage) { _, img in
                if img != nil, let anim = VideoCatalog.models.first(where: { $0.needsImage }) { modelID = anim.id }
            }
        }
    }
}
