import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol MediaProvider: Sendable {
    var id: String { get }
    var name: String { get }
    var kind: MediaKind { get }
    /// Shared Hugging Face ZeroGPU quota (all Spaces draw from the same daily allowance).
    var usesHFQuota: Bool { get }
    func supports(_ req: GenRequest, settings: ProviderSettings) -> Bool
    func run(_ req: GenRequest, settings: ProviderSettings, status: StatusHandler?) async throws -> GenOutput
}

public extension MediaProvider {
    var usesHFQuota: Bool { false }
}

// MARK: - Hugging Face Spaces (free ZeroGPU, verified live 2026-11-28)

public struct HFSpaceProvider: MediaProvider {
    public enum Model: String, Sendable, CaseIterable {
        case zImageTurbo, fluxSchnell, fluxDev, fluxKontext, ltx23, ltxVideo
    }
    public let model: Model
    public init(_ model: Model) { self.model = model }

    public var id: String { "hf.\(model.rawValue)" }
    public var usesHFQuota: Bool { true }

    public var name: String {
        switch model {
        case .zImageTurbo: return "Z-Image Turbo"
        case .fluxSchnell: return "FLUX.1 schnell"
        case .fluxDev: return "FLUX.1 dev"
        case .fluxKontext: return "FLUX.1 Kontext (edit)"
        case .ltx23: return "LTX-2.3 (video + sound)"
        case .ltxVideo: return "LTX-Video"
        }
    }

    public var kind: MediaKind { (model == .ltx23 || model == .ltxVideo) ? .video : .image }

    public var host: URL {
        switch model {
        case .zImageTurbo: return URL(string: "https://tongyi-mai-z-image-turbo.hf.space")!
        case .fluxSchnell: return URL(string: "https://black-forest-labs-flux-1-schnell.hf.space")!
        case .fluxDev: return URL(string: "https://black-forest-labs-flux-1-dev.hf.space")!
        case .fluxKontext: return URL(string: "https://black-forest-labs-flux-1-kontext-dev.hf.space")!
        case .ltx23: return URL(string: "https://lightricks-ltx-2-3.hf.space")!
        case .ltxVideo: return URL(string: "https://lightricks-ltx-video-distilled.hf.space")!
        }
    }

    public func supports(_ req: GenRequest, settings: ProviderSettings) -> Bool {
        switch model {
        case .fluxKontext: return req.inputImage != nil
        case .zImageTurbo, .fluxSchnell, .fluxDev, .ltxVideo: return req.inputImage == nil
        case .ltx23: return true
        }
    }

    /// The exact `data` array for the Space's API, given an optional uploaded file.
    public func payload(_ req: GenRequest, file: [String: Any]?) -> (api: String, data: [Any]) {
        switch model {
        case .zImageTurbo:
            return ("generate", [req.prompt, req.aspect.zImageResolution, req.seed, 8, 3.0, false, [Any]()])
        case .fluxSchnell:
            let s = req.aspect.size(pixels: 1024 * 1024, multiple: 32)
            return ("infer", [req.prompt, req.seed, false, s.width, s.height, 4])
        case .fluxDev:
            let s = req.aspect.size(pixels: 1024 * 1024, multiple: 32)
            return ("infer", [req.prompt, req.seed, false, s.width, s.height, 3.5, 28])
        case .fluxKontext:
            return ("infer", [file ?? NSNull(), req.prompt, req.seed, false, 2.5, 24])
        case .ltx23:
            let s = Self.videoSize(req.aspect)
            return ("generate_video", [file ?? NSNull(), req.prompt, max(2, min(5, req.duration)), false, req.seed, false, s.height, s.width])
        case .ltxVideo:
            let s = Self.videoSize(req.aspect)
            let neg = req.negative.isEmpty ? "worst quality, inconsistent motion, blurry, jittery, distorted" : req.negative
            return ("text_to_video", [req.prompt, neg, NSNull(), NSNull(), s.height, s.width, "text-to-video", max(2, min(5, req.duration)), 9, req.seed, false, 1, true])
        }
    }

    /// Small, quota-friendly video sizes (multiples of 32, ~350k pixels).
    public static func videoSize(_ a: AspectRatio) -> (width: Int, height: Int) {
        a.size(pixels: 768 * 448, multiple: 32, maxSide: 1024)
    }

    public func run(_ req: GenRequest, settings: ProviderSettings, status: StatusHandler?) async throws -> GenOutput {
        let client = GradioClient(host: host, token: settings.hfToken)
        status?(.starting("Sending to \(name)…"))
        var file: [String: Any]?
        if let img = req.inputImage {
            file = try await client.upload(img, filename: "input.jpg", mime: "image/jpeg")
        }
        let p = payload(req, file: file)
        let result = try await client.call(p.api, data: p.data, status: status)
        guard let url = client.firstFileURL(in: result) else { throw GenError.noOutput(name) }
        status?(.working("Downloading…"))
        let data = try await client.download(url)
        let ext = HTTP.sniffExtension(data, fallback: kind == .video ? "mp4" : url.pathExtension.isEmpty ? "png" : url.pathExtension)
        var seed: Int? = req.seed
        if let n = result.last as? Int { seed = n } else if let d = result.last as? Double { seed = Int(d) }
        return GenOutput(data: data, fileExtension: ext, seed: seed, provider: name)
    }
}

// MARK: - Pollinations

public struct PollinationsProvider: MediaProvider {
    public init() {}
    public var id: String { "pollinations" }
    public var name: String { "Pollinations" }
    public var kind: MediaKind { .image }
    public func supports(_ req: GenRequest, settings: ProviderSettings) -> Bool { req.inputImage == nil }

    static let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))

    /// No key: the free "classic" endpoint (1 image per 45 s per IP, its own model).
    /// With the user's own key: gen.pollinations.ai with free-tier models.
    public static func url(for req: GenRequest, key: String, model: String = "zimage") -> URL {
        let text = req.prompt
        let enc = text.addingPercentEncoding(withAllowedCharacters: allowed) ?? "image"
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            let s = req.aspect.size(pixels: 768 * 768, multiple: 16, maxSide: 1344)
            return URL(string: "https://image.pollinations.ai/prompt/\(enc)?width=\(s.width)&height=\(s.height)&seed=\(req.seed)&nologo=true&private=true")!
        }
        let s = req.aspect.size(pixels: 1024 * 1024, multiple: 16, maxSide: 2048)
        return URL(string: "https://gen.pollinations.ai/image/\(enc)?model=\(model)&width=\(s.width)&height=\(s.height)&seed=\(req.seed)&nologo=true&private=true")!
    }

    public func run(_ req: GenRequest, settings: ProviderSettings, status: StatusHandler?) async throws -> GenOutput {
        let key = settings.pollinationsKey.trimmingCharacters(in: .whitespacesAndNewlines)
        var r = URLRequest(url: Self.url(for: req, key: key))
        r.timeoutInterval = 180
        if !key.isEmpty { r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        for attempt in 0..<4 {
            status?(.working(attempt == 0 ? "Painting with Pollinations…" : "Pollinations is busy, retrying (\(attempt))…"))
            let (data, code, headers) = try await HTTP.send(r)
            if code == 200, (headers["content-type"] ?? "").hasPrefix("image") {
                return GenOutput(data: data, fileExtension: HTTP.sniffExtension(data, fallback: "jpg"), seed: req.seed, provider: key.isEmpty ? "Pollinations (free)" : "Pollinations")
            }
            if code == 402 || code == 429 || code == 503 {
                if !key.isEmpty && code == 402 { throw GenError.rateLimited("Pollinations: \(HTTP.snippet(data))") }
                let wait = Double(headers["retry-after"] ?? "") ?? 12
                try await Task.sleep(nanoseconds: UInt64(min(max(wait, 5), 30) * 1_000_000_000))
                continue
            }
            throw GenError.http(code, HTTP.snippet(data))
        }
        throw GenError.rateLimited("Pollinations free limit: 1 image every 45 seconds. A free key lifts this.")
    }
}

// MARK: - AI Horde (volunteer GPUs, anonymous or free account key)

public struct HordeProvider: MediaProvider {
    public init() {}
    public var id: String { "horde" }
    public var name: String { "AI Horde" }
    public var kind: MediaKind { .image }
    public func supports(_ req: GenRequest, settings: ProviderSettings) -> Bool { true }

    /// Anonymous requests must stay at or under 576x576 worth of pixels (Horde rule, 2026-11).
    public static func body(_ req: GenRequest, sourceB64: String?, anonymous: Bool = true) -> [String: Any] {
        let s = req.aspect.size(pixels: anonymous ? 512 * 512 : 512 * 768, multiple: 64, maxSide: anonymous ? 576 : 1024)
        var params: [String: Any] = [
            "width": s.width, "height": s.height, "steps": anonymous ? 20 : 25, "n": 1,
            "sampler_name": "k_euler_a", "cfg_scale": 6.5, "seed": String(req.seed), "karras": true
        ]
        var prompt = req.prompt
        if !req.negative.isEmpty { prompt += " ### " + req.negative }
        var body: [String: Any] = [
            "prompt": prompt, "nsfw": true, "censor_nsfw": false, "r2": true, "shared": false,
            "trusted_workers": false, "slow_workers": true, "replacement_filter": true
        ]
        if let sourceB64 {
            body["source_image"] = sourceB64
            body["source_processing"] = "img2img"
            params["denoising_strength"] = max(0.1, min(1.0, req.strength))
        }
        body["params"] = params
        return body
    }

    public func run(_ req: GenRequest, settings: ProviderSettings, status: StatusHandler?) async throws -> GenOutput {
        let key = settings.hordeKey.trimmingCharacters(in: .whitespacesAndNewlines)
        func make(_ path: String, method: String = "GET") -> URLRequest {
            var r = URLRequest(url: URL(string: "https://aihorde.net/api/v2" + path)!)
            r.httpMethod = method
            r.setValue(key.isEmpty ? "0000000000" : key, forHTTPHeaderField: "apikey")
            r.setValue("Imagine-iOS:2.0:bobbymedia", forHTTPHeaderField: "Client-Agent")
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            return r
        }
        var submit = make("/generate/async", method: "POST")
        submit.httpBody = try JSONSerialization.data(withJSONObject: Self.body(req, sourceB64: req.inputImage?.base64EncodedString(), anonymous: key.isEmpty))
        status?(.starting("Sending to AI Horde…"))
        let (sd, sc, _) = try await HTTP.send(submit)
        guard (200..<300).contains(sc), let id = (HTTP.json(sd) as? [String: Any])?["id"] as? String else {
            throw sc == 429 ? GenError.rateLimited("AI Horde: \(HTTP.snippet(sd))") : GenError.http(sc, "AI Horde: \(HTTP.snippet(sd))")
        }
        let start = Date()
        while true {
            try await Task.sleep(nanoseconds: 4_000_000_000)
            if Task.isCancelled {
                _ = try? await HTTP.send(make("/generate/status/\(id)", method: "DELETE"))
                throw GenError.cancelled
            }
            let (cd, _, _) = try await HTTP.send(make("/generate/check/\(id)"))
            let c = HTTP.json(cd) as? [String: Any] ?? [:]
            if (c["faulted"] as? Bool) == true { throw GenError.server("AI Horde job failed.") }
            if (c["is_possible"] as? Bool) == false { throw GenError.server("No AI Horde worker can make this right now.") }
            if (c["done"] as? Bool) == true { break }
            status?(.queued(position: c["queue_position"] as? Int, eta: (c["wait_time"] as? Double) ?? (c["wait_time"] as? Int).map(Double.init)))
            if Date().timeIntervalSince(start) > 600 { throw GenError.server("AI Horde took too long.") }
        }
        let (fd, _, _) = try await HTTP.send(make("/generate/status/\(id)"))
        guard let gens = (HTTP.json(fd) as? [String: Any])?["generations"] as? [[String: Any]],
              let img = gens.first?["img"] as? String else { throw GenError.noOutput(name) }
        let data: Data
        if img.hasPrefix("http"), let u = URL(string: img) {
            data = try await HTTP.send(URLRequest(url: u)).0
        } else if let d = Data(base64Encoded: img) {
            data = d
        } else { throw GenError.noOutput(name) }
        return GenOutput(data: data, fileExtension: HTTP.sniffExtension(data, fallback: "webp"), seed: Int(gens.first?["seed"] as? String ?? ""), provider: name)
    }
}
