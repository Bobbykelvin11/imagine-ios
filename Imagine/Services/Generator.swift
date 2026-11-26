import Foundation
import CoreML
import UIKit
import StableDiffusion

struct GenParams {
    var prompt: String
    var negativePrompt: String
    var steps: Int
    var guidance: Float
    var seed: UInt32
    var imageCount: Int
    var scheduler: String      // "dpm" or "pndm"
    var startImage: UIImage?
    var strength: Float
}

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}

@MainActor
final class Generator: ObservableObject {
    static let shared = Generator()

    enum Phase: Equatable {
        case idle
        case loading(String)
        case running(step: Int, total: Int)
        case error(String)
    }

    @Published var phase: Phase = .idle
    @Published var preview: UIImage?
    @Published var results: [GalleryItem] = []
    @Published var lastDuration: TimeInterval = 0

    // Settings
    @Published var computeUnits: String = UserDefaults.standard.string(forKey: "computeUnits") ?? "auto" {
        didSet { UserDefaults.standard.set(computeUnits, forKey: "computeUnits"); unload() }
    }
    @Published var reduceMemory: Bool = UserDefaults.standard.object(forKey: "reduceMemory") as? Bool ?? (ModelStore.deviceRAMGB < 7.0) {
        didSet { UserDefaults.standard.set(reduceMemory, forKey: "reduceMemory"); unload() }
    }
    @Published var livePreview: Bool = UserDefaults.standard.bool(forKey: "livePreview") {
        didSet { UserDefaults.standard.set(livePreview, forKey: "livePreview") }
    }

    var isBusy: Bool {
        switch phase { case .loading, .running: return true; default: return false }
    }

    private var pipeline: StableDiffusionPipelineProtocol?
    private var loadedKey: String = ""
    private let cancelFlag = CancelFlag()

    func cancel() { cancelFlag.set(true) }

    func unload() {
        guard !isBusy else { return }
        pipeline?.unloadResources()
        pipeline = nil
        loadedKey = ""
    }

    private func units(for model: ModelInfo) -> MLComputeUnits {
        switch computeUnits {
        case "ane": return .cpuAndNeuralEngine
        case "gpu": return .cpuAndGPU
        case "all": return .all
        default: return model.attention == .splitEinsum ? .cpuAndNeuralEngine : .cpuAndGPU
        }
    }

    func generate(_ p: GenParams, model: ModelInfo, root: URL) {
        guard !isBusy else { return }
        cancelFlag.set(false)
        preview = nil
        results = []
        let units = units(for: model)
        let reduce = reduceMemory || model.isXL
        let key = "\(model.id)|\(units.rawValue)|\(reduce)"
        let needsLoad = (pipeline == nil || loadedKey != key)
        if needsLoad {
            pipeline?.unloadResources()
            pipeline = nil
        }
        let existing = pipeline
        let live = livePreview
        let flag = cancelFlag
        let outSize = ModelStore.outputSize(root: root) ?? CGSize(width: model.isXL ? 768 : 512, height: model.isXL ? 768 : 512)
        phase = needsLoad ? .loading("Loading \(model.name)… the first run on a new model can take a few minutes while iOS prepares it.") : .running(step: 0, total: p.steps)
        UIApplication.shared.isIdleTimerDisabled = true
        let start = Date()

        Task.detached(priority: .userInitiated) {
            do {
                let pipe: StableDiffusionPipelineProtocol
                if let existing {
                    pipe = existing
                } else {
                    let cfg = MLModelConfiguration()
                    cfg.computeUnits = units
                    if model.isXL {
                        pipe = try StableDiffusionXLPipeline(resourcesAt: root, configuration: cfg, reduceMemory: reduce)
                    } else {
                        pipe = try StableDiffusionPipeline(resourcesAt: root, controlNet: [], configuration: cfg, disableSafety: true, reduceMemory: reduce)
                    }
                    try pipe.loadResources()
                    let loaded = pipe
                    await MainActor.run {
                        Generator.shared.pipeline = loaded
                        Generator.shared.loadedKey = key
                    }
                }
                await MainActor.run { Generator.shared.phase = .running(step: 0, total: p.steps) }

                var config = PipelineConfiguration(prompt: p.prompt)
                config.negativePrompt = p.negativePrompt
                config.stepCount = p.steps
                config.guidanceScale = p.guidance
                config.seed = p.seed
                config.imageCount = p.imageCount
                config.disableSafety = true
                config.schedulerType = p.scheduler == "pndm" ? .pndmScheduler : .dpmSolverMultistepScheduler
                if model.isXL {
                    config.encoderScaleFactor = 0.13025
                    config.decoderScaleFactor = 0.13025
                    config.schedulerTimestepSpacing = .karras
                    config.originalSize = Float32(outSize.width)
                    config.targetSize = Float32(outSize.width)
                }
                if let img = p.startImage, ModelStore.hasEncoder(root: root),
                   let cg = Generator.fit(img, to: outSize) {
                    config.startingImage = cg
                    config.strength = p.strength
                }

                let images = try pipe.generateImages(configuration: config) { progress in
                    let step = progress.step + 1
                    var pv: UIImage?
                    if live, step % 4 == 0, step < progress.stepCount, let cg = progress.currentImages.first ?? nil {
                        pv = UIImage(cgImage: cg)
                    }
                    let total = progress.stepCount
                    Task { @MainActor in
                        Generator.shared.phase = .running(step: step, total: total)
                        if let pv { Generator.shared.preview = pv }
                    }
                    return !flag.get()
                }
                let reduceNow = reduce
                await MainActor.run {
                    let g = Generator.shared
                    var saved: [GalleryItem] = []
                    for (i, cg) in images.enumerated() {
                        guard let cg else { continue }
                        let ui = UIImage(cgImage: cg)
                        if let item = GalleryStore.shared.add(image: ui, prompt: p.prompt, negative: p.negativePrompt, seed: p.seed &+ UInt32(i), steps: p.steps, guidance: p.guidance, model: model.name) {
                            saved.append(item)
                        }
                    }
                    g.results = saved
                    g.preview = nil
                    g.lastDuration = Date().timeIntervalSince(start)
                    g.phase = (saved.isEmpty && flag.get()) ? .idle : (saved.isEmpty ? .error("No image came back. Try again, or turn on Reduce memory in Models.") : .idle)
                    if reduceNow, model.isXL { g.pipeline?.unloadResources() }
                    UIApplication.shared.isIdleTimerDisabled = false
                }
            } catch {
                await MainActor.run {
                    let g = Generator.shared
                    g.phase = flag.get() ? .idle : .error(error.localizedDescription)
                    g.pipeline = nil
                    g.loadedKey = ""
                    UIApplication.shared.isIdleTimerDisabled = false
                }
            }
        }
    }

    /// Scales and center-crops an image to the exact size the model needs.
    nonisolated static func fit(_ image: UIImage, to size: CGSize) -> CGImage? {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = true
        let r = UIGraphicsImageRenderer(size: size, format: fmt)
        let out = r.image { _ in
            let s = max(size.width / image.size.width, size.height / image.size.height)
            let w = image.size.width * s, h = image.size.height * s
            image.draw(in: CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h))
        }
        return out.cgImage
    }
}
