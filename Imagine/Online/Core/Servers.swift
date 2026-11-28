import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

func normalizedBase(_ s: String) -> URL? {
    var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty else { return nil }
    if !t.lowercased().hasPrefix("http") { t = "http://" + t }
    while t.hasSuffix("/") { t.removeLast() }
    return URL(string: t)
}

// MARK: - Automatic1111 / Forge / SD.Next (self-hosted, e.g. Flux on the Oracle VM)

public struct A1111Provider: MediaProvider {
    public init() {}
    public var id: String { "server.a1111" }
    public var name: String { "My server (A1111/Forge)" }
    public var kind: MediaKind { .image }
    public func supports(_ req: GenRequest, settings: ProviderSettings) -> Bool { normalizedBase(settings.a1111URL) != nil }

    public static func body(_ req: GenRequest, initB64: String?) -> [String: Any] {
        let s = req.aspect.size(pixels: 1024 * 1024, multiple: 64)
        var b: [String: Any] = [
            "prompt": req.prompt, "negative_prompt": req.negative, "width": s.width, "height": s.height,
            "steps": 20, "cfg_scale": 5, "seed": req.seed, "batch_size": 1, "send_images": true, "save_images": false
        ]
        if let initB64 { b["init_images"] = [initB64]; b["denoising_strength"] = req.strength }
        return b
    }

    public func run(_ req: GenRequest, settings: ProviderSettings, status: StatusHandler?) async throws -> GenOutput {
        guard let base = normalizedBase(settings.a1111URL) else { throw GenError.notConfigured("Add your A1111/Forge server address in Settings.") }
        let path = req.inputImage == nil ? "/sdapi/v1/txt2img" : "/sdapi/v1/img2img"
        var r = URLRequest(url: base.appendingPathComponent(path))
        r.httpMethod = "POST"
        r.timeoutInterval = 600
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: Self.body(req, initB64: req.inputImage?.base64EncodedString()))
        status?(.working("Your server is painting…"))
        let (d, c, _) = try await HTTP.send(r)
        guard (200..<300).contains(c) else { throw GenError.http(c, HTTP.snippet(d)) }
        guard let imgs = (HTTP.json(d) as? [String: Any])?["images"] as? [String], let first = imgs.first,
              let data = Data(base64Encoded: first.components(separatedBy: ",").last ?? first) else { throw GenError.noOutput(name) }
        return GenOutput(data: data, fileExtension: HTTP.sniffExtension(data, fallback: "png"), seed: req.seed, provider: name)
    }
}

// MARK: - ComfyUI (self-hosted; images with Flux, videos with Wan 2.x / LTX-Video)

public enum ComfyUI {
    /// Basic text-to-image workflow in ComfyUI "API format". Works with any single-file checkpoint
    /// (e.g. flux1-schnell-fp8.safetensors). Replace it with your own exported workflow in Settings.
    public static let defaultImageWorkflow = """
    {"3":{"class_type":"KSampler","inputs":{"seed":"{{SEED}}","steps":"{{STEPS}}","cfg":"{{CFG}}","sampler_name":"euler","scheduler":"simple","denoise":1,"model":["4",0],"positive":["6",0],"negative":["7",0],"latent_image":["5",0]}},
     "4":{"class_type":"CheckpointLoaderSimple","inputs":{"ckpt_name":"{{CHECKPOINT}}"}},
     "5":{"class_type":"EmptyLatentImage","inputs":{"width":"{{WIDTH}}","height":"{{HEIGHT}}","batch_size":1}},
     "6":{"class_type":"CLIPTextEncode","inputs":{"text":"{{PROMPT}}","clip":["4",1]}},
     "7":{"class_type":"CLIPTextEncode","inputs":{"text":"{{NEGATIVE}}","clip":["4",1]}},
     "8":{"class_type":"VAEDecode","inputs":{"samples":["3",0],"vae":["4",2]}},
     "9":{"class_type":"SaveImage","inputs":{"filename_prefix":"Imagine","images":["8",0]}}}
    """

    /// Replaces {{PLACEHOLDERS}} in a workflow. A string that is exactly a placeholder becomes the typed
    /// value (number stays a number); placeholders inside longer strings are substituted as text.
    public static func fill(_ template: String, values: [String: Any]) throws -> [String: Any] {
        guard let obj = HTTP.json(Data(template.utf8)) as? [String: Any] else {
            throw GenError.notConfigured("The ComfyUI workflow isn't valid JSON. Export it with \"Save (API Format)\".")
        }
        func walk(_ v: Any) -> Any {
            if let s = v as? String {
                if s.hasPrefix("{{"), s.hasSuffix("}}") {
                    let key = String(s.dropFirst(2).dropLast(2))
                    if let val = values[key] { return val }
                }
                var out = s
                for (k, val) in values where out.contains("{{\(k)}}") { out = out.replacingOccurrences(of: "{{\(k)}}", with: "\(val)") }
                return out
            }
            if let d = v as? [String: Any] { return d.mapValues(walk) }
            if let a = v as? [Any] { return a.map(walk) }
            return v
        }
        return walk(obj) as? [String: Any] ?? obj
    }

    /// Picks the first output file from a /history/{id} entry (images, gifs or videos).
    public static func firstOutput(_ history: [String: Any]) -> (filename: String, subfolder: String, type: String)? {
        guard let outputs = history["outputs"] as? [String: Any] else { return nil }
        var best: (String, String, String)?
        for key in outputs.keys.sorted() {
            guard let node = outputs[key] as? [String: Any] else { continue }
            for field in ["videos", "gifs", "images"] {
                if let files = node[field] as? [[String: Any]], let f = files.first, let name = f["filename"] as? String {
                    let item = (name, f["subfolder"] as? String ?? "", f["type"] as? String ?? "output")
                    if field != "images" { return item }
                    if best == nil { best = item }
                }
            }
        }
        return best
    }
}

public struct ComfyProvider: MediaProvider {
    public let kind: MediaKind
    public init(kind: MediaKind) { self.kind = kind }
    public var id: String { "server.comfy.\(kind.rawValue)" }
    public var name: String { kind == .video ? "My server (ComfyUI video)" : "My server (ComfyUI)" }

    func workflow(_ s: ProviderSettings) -> String { kind == .video ? s.comfyVideoWorkflow : s.comfyImageWorkflow }

    public func supports(_ req: GenRequest, settings: ProviderSettings) -> Bool {
        guard normalizedBase(settings.comfyURL) != nil else { return false }
        let wf = workflow(settings)
        if wf.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        if req.inputImage != nil { return wf.contains("{{IMAGE}}") }
        return true
    }

    public func run(_ req: GenRequest, settings: ProviderSettings, status: StatusHandler?) async throws -> GenOutput {
        guard let base = normalizedBase(settings.comfyURL) else { throw GenError.notConfigured("Add your ComfyUI address in Settings.") }
        var imageName = ""
        if let img = req.inputImage {
            var up = URLRequest(url: base.appendingPathComponent("/upload/image"))
            up.httpMethod = "POST"
            let boundary = "imagine-\(UUID().uuidString)"
            up.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            up.httpBody = HTTP.multipart(field: "image", filename: "imagine-\(UUID().uuidString.prefix(8)).jpg", mime: "image/jpeg", data: img, boundary: boundary)
            let (d, c, _) = try await HTTP.send(up)
            guard (200..<300).contains(c), let n = (HTTP.json(d) as? [String: Any])?["name"] as? String else { throw GenError.http(c, "ComfyUI upload: \(HTTP.snippet(d))") }
            imageName = n
        }
        let size = kind == .video ? HFSpaceProvider.videoSize(req.aspect) : req.aspect.size(pixels: 1024 * 1024, multiple: 64)
        let fps = 16
        let values: [String: Any] = [
            "PROMPT": req.prompt, "NEGATIVE": req.negative, "SEED": req.seed, "WIDTH": size.width, "HEIGHT": size.height,
            "STEPS": 4, "CFG": 1.0, "CHECKPOINT": settings.comfyCheckpoint, "IMAGE": imageName,
            "FRAMES": Int(req.duration * Double(fps)) / 4 * 4 + 1, "FPS": fps, "DURATION": req.duration, "STRENGTH": req.strength
        ]
        let graph = try ComfyUI.fill(workflow(settings), values: values)
        var r = URLRequest(url: base.appendingPathComponent("/prompt"))
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: ["prompt": graph, "client_id": "imagine-ios"])
        status?(.starting("Sending to your ComfyUI…"))
        let (pd, pc, _) = try await HTTP.send(r)
        guard (200..<300).contains(pc), let pid = (HTTP.json(pd) as? [String: Any])?["prompt_id"] as? String else {
            throw GenError.http(pc, "ComfyUI: \(HTTP.snippet(pd))")
        }
        let start = Date()
        while true {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            if Task.isCancelled { throw GenError.cancelled }
            let (hd, _, _) = try await HTTP.send(URLRequest(url: base.appendingPathComponent("/history/\(pid)")))
            if let all = HTTP.json(hd) as? [String: Any], let h = all[pid] as? [String: Any] {
                if let st = h["status"] as? [String: Any], (st["status_str"] as? String) == "error" { throw GenError.server("ComfyUI reported an error running the workflow.") }
                if let f = ComfyUI.firstOutput(h) {
                    var comps = URLComponents(url: base.appendingPathComponent("/view"), resolvingAgainstBaseURL: false)!
                    comps.queryItems = [URLQueryItem(name: "filename", value: f.filename), URLQueryItem(name: "subfolder", value: f.subfolder), URLQueryItem(name: "type", value: f.type)]
                    let (data, c, _) = try await HTTP.send(URLRequest(url: comps.url!))
                    guard (200..<300).contains(c) else { throw GenError.http(c, "ComfyUI download") }
                    let ext = HTTP.sniffExtension(data, fallback: (f.filename as NSString).pathExtension)
                    return GenOutput(data: data, fileExtension: ext, seed: req.seed, provider: name)
                }
            }
            status?(.working("Your server is working… \(Int(Date().timeIntervalSince(start)))s"))
            if Date().timeIntervalSince(start) > 1200 { throw GenError.server("ComfyUI took longer than 20 minutes.") }
        }
    }
}

// MARK: - Fallback runner

public struct Attempt: Sendable, Equatable {
    public var provider: String
    public var error: String
}

public struct FallbackResult: Sendable {
    public var output: GenOutput
    public var failures: [Attempt]
}

public enum Fallback {
    /// Tries providers in order. After a Hugging Face quota error, other HF Spaces are skipped
    /// because they share the same daily ZeroGPU allowance.
    public static func run(_ providers: [MediaProvider], request: GenRequest, settings: ProviderSettings,
                           status: StatusHandler?) async throws -> FallbackResult {
        var failures: [Attempt] = []
        var hfOut = false
        let usable = providers.filter { $0.supports(request, settings: settings) }
        if usable.isEmpty { throw GenError.unsupported("No service can do this. Check Settings.") }
        for p in usable {
            if Task.isCancelled { throw GenError.cancelled }
            if hfOut && p.usesHFQuota { continue }
            do {
                let out = try await p.run(request, settings: settings, status: status)
                return FallbackResult(output: out, failures: failures)
            } catch GenError.cancelled {
                throw GenError.cancelled
            } catch is CancellationError {
                throw GenError.cancelled
            } catch {
                if case GenError.rateLimited = error, p.usesHFQuota { hfOut = true }
                failures.append(Attempt(provider: p.name, error: error.localizedDescription))
                if usable.count > 1 { status?(.starting("\(p.name) didn't work, trying the next one…")) }
            }
        }
        let summary = failures.map { "\($0.provider): \($0.error)" }.joined(separator: "\n")
        throw GenError.server("Every free service failed:\n\(summary)")
    }
}
