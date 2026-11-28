import SwiftUI

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()
    enum Tab: Hashable { case imagine, video, gallery, settings }
    @Published var tab: Tab = .imagine
    // Online hand-offs
    @Published var editImage: UIImage?
    @Published var remixPrompt: String?
    @Published var videoImage: UIImage?
    // Offline (on-device) hand-offs
    @Published var reuse: GalleryItem?
    @Published var startImage: UIImage?
}

@main
struct ImagineApp: App {
    @StateObject private var app = AppState.shared
    @StateObject private var models = ModelStore.shared
    @StateObject private var gallery = GalleryStore.shared
    @StateObject private var generator = Generator.shared
    @StateObject private var engine = OnlineEngine.shared

    var body: some Scene {
        WindowGroup {
            TabView(selection: $app.tab) {
                ImagineView()
                    .tabItem { Label("Imagine", systemImage: "sparkles") }
                    .tag(AppState.Tab.imagine)
                VideoStudioView()
                    .tabItem { Label("Video", systemImage: "film.stack") }
                    .tag(AppState.Tab.video)
                GalleryView()
                    .tabItem { Label("Gallery", systemImage: "photo.on.rectangle") }
                    .tag(AppState.Tab.gallery)
                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gearshape") }
                    .tag(AppState.Tab.settings)
            }
            .tint(Color(red: 0.62, green: 0.45, blue: 1.0))
            .environmentObject(app)
            .environmentObject(models)
            .environmentObject(gallery)
            .environmentObject(generator)
            .environmentObject(engine)
            .preferredColorScheme(.dark)
        }
    }
}
