import Foundation

enum ModelSource: Codable, Hashable {
    /// A folder inside a Hugging Face repo that holds compiled .mlmodelc files.
    case hfFolder(repo: String, path: String)
    /// A .zip inside a Hugging Face repo that holds compiled .mlmodelc files.
    case hfZip(repo: String, path: String)
    /// Any direct link to a .zip with compiled .mlmodelc files.
    case url(String)
    /// Imported from Files.
    case local
}

enum Attention: String, Codable, Hashable {
    case splitEinsum   // best on the Neural Engine
    case original      // best on the GPU
}

struct ModelInfo: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var details: String
    var source: ModelSource
    var sizeMB: Int
    var isXL: Bool
    var attention: Attention
    var minRAMGB: Int
    var recommendedSteps: Int
    var isCustom: Bool = false
}

enum ModelCatalog {
    static let builtIn: [ModelInfo] = [
        ModelInfo(
            id: "sd21-base-pal",
            name: "Stable Diffusion 2.1 (fast)",
            details: "Apple's 6-bit model. Smallest and quickest, works on most iPhones. 512×512.",
            source: .hfFolder(repo: "apple/coreml-stable-diffusion-2-1-base-palettized", path: "split_einsum_v2/compiled"),
            sizeMB: 1141, isXL: false, attention: .splitEinsum, minRAMGB: 4, recommendedSteps: 20),
        ModelInfo(
            id: "sd15-pal",
            name: "Stable Diffusion 1.5",
            details: "Apple's 6-bit SD 1.5. Classic model with the widest style range. 512×512.",
            source: .hfFolder(repo: "apple/coreml-stable-diffusion-v1-5-palettized", path: "split_einsum_v2/compiled"),
            sizeMB: 1566, isXL: false, attention: .splitEinsum, minRAMGB: 4, recommendedSteps: 20),
        ModelInfo(
            id: "realistic-vision-51",
            name: "Realistic Vision 5.1 (photoreal)",
            details: "Community SD 1.5 model for realistic photos of people, pets and places. 512×512. Big download.",
            source: .hfZip(repo: "coreml-community/coreml-realisticVision-v51VAE_cn", path: "split_einsum/realisticVision-v51VAE_split-einsum_cn.zip"),
            sizeMB: 3579, isXL: false, attention: .splitEinsum, minRAMGB: 6, recommendedSteps: 25),
        ModelInfo(
            id: "realistic-vision-51-portrait",
            name: "Realistic Vision 5.1 portrait",
            details: "Same photoreal model in tall 512×768 portrait size. Runs on the GPU. Big download.",
            source: .hfZip(repo: "coreml-community/coreml-realisticVision-v51VAE_cn", path: "original/512x768/realisticVision-v51VAE_original_512x768_cn.zip"),
            sizeMB: 3578, isXL: false, attention: .original, minRAMGB: 6, recommendedSteps: 25),
        ModelInfo(
            id: "dreamlike-photoreal",
            name: "Dreamlike Photoreal 2.0",
            details: "Community model for detailed, photo-style art. 512×512. Big download.",
            source: .hfZip(repo: "coreml-community/coreml-dreamlike-photoreal", path: "split-einsum/dreamlikePhotoreal20_split-einsum.zip"),
            sizeMB: 1973, isXL: false, attention: .splitEinsum, minRAMGB: 6, recommendedSteps: 25),
        ModelInfo(
            id: "sdxl-ios",
            name: "Stable Diffusion XL (best quality)",
            details: "Apple's SDXL for iPhone. Highest quality, 768×768. Needs an iPhone 15 Pro or newer (8 GB RAM) and takes a few minutes per image.",
            source: .hfFolder(repo: "apple/coreml-stable-diffusion-xl-base-ios", path: "coreml-stable-diffusion-xl-base-ios_split_einsum_compiled"),
            sizeMB: 3053, isXL: true, attention: .splitEinsum, minRAMGB: 8, recommendedSteps: 20)
    ]
}
