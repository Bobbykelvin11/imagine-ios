import SwiftUI

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()
    enum Tab: Hashable { case create, gallery, video, models }
    @Published var tab: Tab = .create
    // Hand-offs between tabs
    @Published var reuse: GalleryItem?
    @Published var startImage: UIImage?
    @Published var videoImage: UIImage?
}

@main
struct ImagineApp: App {
    @StateObject private var app = AppState.shared
    @StateObject private var models = ModelStore.shared
    @StateObject private var gallery = GalleryStore.shared
    @StateObject private var generator = Generator.shared
    @StateObject private var video = VideoService.shared

    var body: some Scene {
        WindowGroup {
            TabView(selection: $app.tab) {
                CreateView()
                    .tabItem { Label("Create", systemImage: "wand.and.stars") }
                    .tag(AppState.Tab.create)
                GalleryView()
                    .tabItem { Label("Gallery", systemImage: "photo.on.rectangle") }
                    .tag(AppState.Tab.gallery)
                VideoView()
                    .tabItem { Label("Video", systemImage: "film") }
                    .tag(AppState.Tab.video)
                ModelsView()
                    .tabItem { Label("Models", systemImage: "cpu") }
                    .tag(AppState.Tab.models)
            }
            .environmentObject(app)
            .environmentObject(models)
            .environmentObject(gallery)
            .environmentObject(generator)
            .environmentObject(video)
            .preferredColorScheme(.dark)
        }
    }
}
