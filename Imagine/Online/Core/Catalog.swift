import Foundation

public enum ImageEngine: String, CaseIterable, Codable, Identifiable, Sendable {
    case auto, zImage, fluxSchnell, fluxDev, pollinations, horde, server
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .auto: return "Auto (best free)"
        case .zImage: return "Z-Image Turbo · photoreal, fastest"
        case .fluxSchnell: return "FLUX.1 schnell · fast"
        case .fluxDev: return "FLUX.1 dev · best detail"
        case .pollinations: return "Pollinations"
        case .horde: return "AI Horde · volunteer GPUs"
        case .server: return "My server (A1111 / ComfyUI)"
        }
    }
}

public enum VideoEngine: String, CaseIterable, Codable, Identifiable, Sendable {
    case auto, ltx23, ltxVideo, server
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .auto: return "Auto (best free)"
        case .ltx23: return "LTX-2.3 · video with sound"
        case .ltxVideo: return "LTX-Video · text to video"
        case .server: return "My server (ComfyUI: Wan / LTX)"
        }
    }
}

public enum Catalog {
    static func dedupe(_ list: [MediaProvider]) -> [MediaProvider] {
        var seen = Set<String>()
        return list.filter { seen.insert($0.id).inserted }
    }

    static func servers(_ s: ProviderSettings, kind: MediaKind) -> [MediaProvider] {
        var out: [MediaProvider] = []
        if kind == .image, normalizedBase(s.a1111URL) != nil { out.append(A1111Provider()) }
        if normalizedBase(s.comfyURL) != nil { out.append(ComfyProvider(kind: kind)) }
        return out
    }

    /// Ordered providers to try for an image request.
    public static func imageChain(_ engine: ImageEngine, settings s: ProviderSettings, editing: Bool) -> [MediaProvider] {
        let free: [MediaProvider]
        if editing {
            free = [HFSpaceProvider(.fluxKontext), HordeProvider()]
        } else {
            free = [HFSpaceProvider(.zImageTurbo), HFSpaceProvider(.fluxSchnell), HFSpaceProvider(.fluxDev), PollinationsProvider(), HordeProvider()]
        }
        var first: [MediaProvider] = []
        switch engine {
        case .auto: break
        case .zImage: first = editing ? [] : [HFSpaceProvider(.zImageTurbo)]
        case .fluxSchnell: first = editing ? [] : [HFSpaceProvider(.fluxSchnell)]
        case .fluxDev: first = editing ? [] : [HFSpaceProvider(.fluxDev)]
        case .pollinations: first = editing ? [] : [PollinationsProvider()]
        case .horde: first = [HordeProvider()]
        case .server: first = servers(s, kind: .image)
        }
        return dedupe(first + free + (engine == .server ? [] : servers(s, kind: .image)))
    }

    public static func videoChain(_ engine: VideoEngine, settings s: ProviderSettings, hasImage: Bool) -> [MediaProvider] {
        var free: [MediaProvider] = [HFSpaceProvider(.ltx23)]
        if !hasImage { free.append(HFSpaceProvider(.ltxVideo)) }
        var first: [MediaProvider] = []
        switch engine {
        case .auto: break
        case .ltx23: first = [HFSpaceProvider(.ltx23)]
        case .ltxVideo: first = hasImage ? [] : [HFSpaceProvider(.ltxVideo)]
        case .server: first = servers(s, kind: .video)
        }
        return dedupe(first + free + (engine == .server ? [] : servers(s, kind: .video)))
    }
}
