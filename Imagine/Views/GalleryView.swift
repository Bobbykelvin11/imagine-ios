import SwiftUI
import AVKit

struct GalleryView: View {
    @EnvironmentObject var gallery: GalleryStore
    @State private var detail: GalleryItem?

    var body: some View {
        NavigationStack {
            Group {
                if gallery.items.isEmpty {
                    ContentUnavailableView("Nothing yet", systemImage: "photo.on.rectangle", description: Text("Images and videos you make show up here."))
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 4)], spacing: 4) {
                            ForEach(gallery.items) { item in
                                Button { detail = item } label: { Thumb(item: item) }
                            }
                        }
                        .padding(4)
                    }
                }
            }
            .navigationTitle("Gallery")
            .sheet(item: $detail) { item in
                NavigationStack { GalleryDetailView(item: item) }
            }
        }
    }
}

struct Thumb: View {
    let item: GalleryItem
    var body: some View {
        Color.gray.opacity(0.2)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if item.kind == .image, let img = GalleryStore.shared.image(item) {
                    Image(uiImage: img).resizable().scaledToFill()
                } else {
                    Image(systemName: "play.rectangle.fill").font(.largeTitle)
                }
            }
            .clipped()
            .contentShape(Rectangle())
    }
}

struct GalleryDetailView: View {
    let item: GalleryItem
    @EnvironmentObject var app: AppState
    @EnvironmentObject var gallery: GalleryStore
    @EnvironmentObject var engine: OnlineEngine
    @Environment(\.dismiss) private var dismiss
    @State private var saved = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if item.kind == .image, let img = gallery.image(item) {
                    Image(uiImage: img).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    VideoPlayer(player: AVPlayer(url: gallery.url(item)))
                        .frame(height: 360)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                Text(item.prompt).font(.body).textSelection(.enabled)
                if !item.negativePrompt.isEmpty {
                    Text("Avoid: \(item.negativePrompt)").font(.caption).foregroundStyle(.secondary)
                }
                Text(meta).font(.caption).foregroundStyle(.secondary)

                HStack {
                    Button { saveToPhotos() } label: { Label(saved ? "Saved" : "Save to Photos", systemImage: saved ? "checkmark" : "square.and.arrow.down") }
                        .buttonStyle(.borderedProminent)
                    ShareLink(item: gallery.url(item)) { Label("Share", systemImage: "square.and.arrow.up") }
                        .buttonStyle(.bordered)
                }
                if item.kind == .image, let img = gallery.image(item) {
                    Button {
                        engine.generateVideo(prompt: item.prompt, aspect: aspectOf(img), from: img, duration: 3)
                        app.tab = .imagine; dismiss()
                    } label: { Label("Make video (AI, free)", systemImage: "sparkles.tv") }
                        .buttonStyle(.borderedProminent)
                    HStack {
                        Button { app.editImage = img; app.tab = .imagine; dismiss() } label: { Label("Edit", systemImage: "wand.and.stars") }
                        Button { app.remixPrompt = item.prompt; app.tab = .imagine; dismiss() } label: { Label("More like this", systemImage: "arrow.triangle.2.circlepath") }
                    }
                    .buttonStyle(.bordered)
                    HStack {
                        Button { engine.makeClip(from: [img], prompt: item.prompt, style: .kenBurns, seconds: 4); app.tab = .imagine; dismiss() } label: { Label("Zoom clip (offline)", systemImage: "film") }
                        Button { app.videoImage = img; app.tab = .video; dismiss() } label: { Label("Video options", systemImage: "slider.horizontal.3") }
                    }
                    .buttonStyle(.bordered)
                }
                Button(role: .destructive) { gallery.delete(item); dismiss() } label: { Label("Delete", systemImage: "trash") }
                    .buttonStyle(.bordered)
            }
            .padding()
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }

    private var meta: String {
        var parts = [item.model]
        if item.kind == .image {
            parts.append("seed \(item.seed)")
            if item.steps > 0 { parts.append("\(item.steps) steps") }
            if item.guidance > 0 { parts.append(String(format: "guidance %.1f", item.guidance)) }
        }
        parts.append(item.date.formatted(date: .abbreviated, time: .shortened))
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func saveToPhotos() {
        OnlineEngine.saveToPhotos(item) { ok in saved = ok }
    }
}
