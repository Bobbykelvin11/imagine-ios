import Foundation
import UIKit
import Photos

/// One image or video being made (shown as a live tile in the feed).
struct Job: Identifiable, Equatable {
    enum State: Equatable { case running, failed(String), done(GalleryItem) }
    let id = UUID()
    var kind: MediaKind
    var prompt: String
    var aspect: AspectRatio
    var started = Date()
    var status = "Starting…"
    var state: State = .running
    var preview: UIImage?
}

@MainActor
final class OnlineEngine: ObservableObject {
    static let shared = OnlineEngine()

    @Published var jobs: [Job] = []
    @Published var settings: ProviderSettings { didSet { persist() } }
    @Published var imageEngine: ImageEngine = ImageEngine(rawValue: UserDefaults.standard.string(forKey: "imageEngine") ?? "") ?? .auto {
        didSet { UserDefaults.standard.set(imageEngine.rawValue, forKey: "imageEngine") }
    }
    @Published var videoEngine: VideoEngine = VideoEngine(rawValue: UserDefaults.standard.string(forKey: "videoEngine") ?? "") ?? .auto {
        didSet { UserDefaults.standard.set(videoEngine.rawValue, forKey: "videoEngine") }
    }
    @Published var autoSave: Bool = UserDefaults.standard.bool(forKey: "autoSave") {
        didSet { UserDefaults.standard.set(autoSave, forKey: "autoSave") }
    }
    @Published var imagesPerPrompt: Int = (UserDefaults.standard.object(forKey: "imagesPerPrompt") as? Int) ?? 2 {
        didSet { UserDefaults.standard.set(imagesPerPrompt, forKey: "imagesPerPrompt") }
    }
    @Published var endless: Bool = UserDefaults.standard.bool(forKey: "endless") {
        didSet { UserDefaults.standard.set(endless, forKey: "endless") }
    }

    private var tasks: [UUID: Task<Void, Never>] = [:]

    init() {
        var s = ProviderSettings()
        let d = UserDefaults.standard
        s.hfToken = Keychain.get("hfToken")
        s.pollinationsKey = Keychain.get("pollinationsKey")
        s.hordeKey = Keychain.get("hordeKey")
        s.a1111URL = d.string(forKey: "a1111URL") ?? ""
        s.comfyURL = d.string(forKey: "comfyURL") ?? ""
        s.comfyImageWorkflow = d.string(forKey: "comfyImageWorkflow") ?? ComfyUI.defaultImageWorkflow
        s.comfyVideoWorkflow = d.string(forKey: "comfyVideoWorkflow") ?? ""
        s.comfyCheckpoint = d.string(forKey: "comfyCheckpoint") ?? s.comfyCheckpoint
        settings = s
    }

    private func persist() {
        let s = settings, d = UserDefaults.standard
        Keychain.set(s.hfToken.trimmingCharacters(in: .whitespacesAndNewlines), for: "hfToken")
        Keychain.set(s.pollinationsKey.trimmingCharacters(in: .whitespacesAndNewlines), for: "pollinationsKey")
        Keychain.set(s.hordeKey.trimmingCharacters(in: .whitespacesAndNewlines), for: "hordeKey")
        d.set(s.a1111URL, forKey: "a1111URL")
        d.set(s.comfyURL, forKey: "comfyURL")
        d.set(s.comfyImageWorkflow, forKey: "comfyImageWorkflow")
        d.set(s.comfyVideoWorkflow, forKey: "comfyVideoWorkflow")
        d.set(s.comfyCheckpoint, forKey: "comfyCheckpoint")
    }

    var runningCount: Int { jobs.filter { $0.state == .running }.count }

    // MARK: Images

    /// Starts `count` images in parallel, each with its own seed and its own fallback chain.
    func generateImages(prompt: String, negative: String = "", aspect: AspectRatio, editing photo: UIImage? = nil, count: Int? = nil) {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let n = photo != nil ? 1 : max(1, min(4, count ?? imagesPerPrompt))
        let input = photo.flatMap { Self.jpeg($0, maxSide: 1024) }
        let chain = Catalog.imageChain(imageEngine, settings: settings, editing: input != nil)
        for _ in 0..<n {
            var req = GenRequest(prompt: text)
            req.negative = negative
            req.aspect = aspect
            req.inputImage = input
            start(kind: .image, request: req, chain: chain, preview: photo)
        }
    }

    // MARK: Video

    func generateVideo(prompt: String, aspect: AspectRatio, from photo: UIImage?, duration: Double) {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || photo != nil else { return }
        var req = GenRequest(prompt: text.isEmpty ? "make this image come alive, natural cinematic motion" : text)
        req.aspect = aspect
        req.duration = duration
        req.inputImage = photo.flatMap { Self.jpeg($0, maxSide: 1024) }
        let chain = Catalog.videoChain(videoEngine, settings: settings, hasImage: req.inputImage != nil)
        start(kind: .video, request: req, chain: chain, preview: photo)
    }

    /// Free and unlimited: an MP4 made on the phone from one or more pictures.
    func makeClip(from images: [UIImage], prompt: String, style: ClipMaker.Style, seconds: Double) {
        guard !images.isEmpty else { return }
        var job = Job(kind: .video, prompt: prompt.isEmpty ? "On-device clip" : prompt, aspect: .square)
        job.preview = images.first
        job.status = "Making the clip on your iPhone…"
        jobs.insert(job, at: 0)
        let id = job.id
        let title = job.prompt
        tasks[id] = Task {
            do {
                let url = try await ClipMaker.make(images: images, style: style, secondsPerImage: seconds)
                let item = GalleryStore.shared.add(videoAt: url, prompt: title, model: "On-device clip")
                finish(id, item: item)
            } catch {
                update(id) { $0.state = .failed(error.localizedDescription) }
            }
        }
    }

    // MARK: Shared

    private func start(kind: MediaKind, request: GenRequest, chain: [MediaProvider], preview: UIImage?) {
        var job = Job(kind: kind, prompt: request.prompt, aspect: request.aspect)
        job.preview = preview
        jobs.insert(job, at: 0)
        let id = job.id
        let settings = self.settings
        UIApplication.shared.isIdleTimerDisabled = true
        tasks[id] = Task {
            do {
                let result = try await Fallback.run(chain, request: request, settings: settings) { st in
                    Task { @MainActor in OnlineEngine.shared.update(id) { $0.status = Self.describe(st) } }
                }
                let out = result.output
                let item = GalleryStore.shared.add(data: out.data, ext: out.fileExtension, kind: kind == .video ? .video : .image,
                                                   prompt: request.prompt, negative: request.negative,
                                                   seed: UInt32(truncatingIfNeeded: out.seed ?? request.seed), model: out.provider)
                finish(id, item: item)
            } catch {
                update(id) { $0.state = .failed(error.localizedDescription) }
            }
            tasks[id] = nil
            if runningCount == 0 { UIApplication.shared.isIdleTimerDisabled = false }
        }
    }

    private func finish(_ id: UUID, item: GalleryItem?) {
        guard let item else { update(id) { $0.state = .failed("Couldn't save the result.") }; return }
        update(id) { $0.state = .done(item) }
        if autoSave { Self.saveToPhotos(item) }
        // Finished tiles live on in the gallery feed below; drop the job tile shortly after.
        Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            jobs.removeAll { $0.id == id }
        }
    }

    func update(_ id: UUID, _ change: (inout Job) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[i])
    }

    func cancel(_ id: UUID) {
        tasks[id]?.cancel()
        tasks[id] = nil
        jobs.removeAll { $0.id == id }
        if runningCount == 0 { UIApplication.shared.isIdleTimerDisabled = false }
    }

    func dismiss(_ id: UUID) { jobs.removeAll { $0.id == id } }

    nonisolated static func describe(_ s: GenStatus) -> String {
        switch s {
        case .starting(let t): return t
        case .working(let t): return t
        case .queued(let pos, let eta):
            var t = "In line"
            if let pos { t += " #\(pos)" }
            if let eta, eta > 0 { t += " · ~\(Int(eta))s" }
            return pos == nil && eta == nil ? "Generating…" : t
        }
    }

    static func jpeg(_ image: UIImage, maxSide: CGFloat) -> Data? {
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        let img = UIGraphicsImageRenderer(size: size, format: fmt).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        return img.jpegData(compressionQuality: 0.9)
    }

    static func saveToPhotos(_ item: GalleryItem, done: ((Bool) -> Void)? = nil) {
        let url = GalleryStore.shared.url(item)
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { DispatchQueue.main.async { done?(false) }; return }
            // Photos doesn't take every format (e.g. WebP), so images are re-encoded as JPEG.
            let photoData: Data? = item.kind == .image ? UIImage(contentsOfFile: url.path)?.jpegData(compressionQuality: 0.95) : nil
            PHPhotoLibrary.shared().performChanges({
                if item.kind == .video {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                } else if let photoData {
                    PHAssetCreationRequest.forAsset().addResource(with: .photo, data: photoData, options: nil)
                }
            }) { ok, _ in DispatchQueue.main.async { done?(ok) } }
        }
    }
}
