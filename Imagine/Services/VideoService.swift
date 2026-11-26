import Foundation
import UIKit

struct VideoModel: Identifiable, Hashable {
    let id: String
    let name: String
    let details: String
    let needsImage: Bool
}

enum VideoCatalog {
    static let models: [VideoModel] = [
        VideoModel(id: "fal-ai/wan/v2.2-a14b/text-to-video", name: "Wan 2.2 (open source, best)", details: "Open-source Wan 2.2 14B. About 5 s clips, 480p–720p.", needsImage: false),
        VideoModel(id: "fal-ai/wan/v2.2-5b/text-to-video", name: "Wan 2.2 5B (open source, cheaper)", details: "Smaller open-source Wan model, faster and cheaper.", needsImage: false),
        VideoModel(id: "fal-ai/ltx-video-13b-distilled", name: "LTX-Video 13B (open source, fast)", details: "Open-source LTX-Video, quick drafts.", needsImage: false),
        VideoModel(id: "fal-ai/wan/v2.2-a14b/image-to-video", name: "Wan 2.2 animate an image", details: "Brings one of your images to life. Pick a start image.", needsImage: true)
    ]
}

enum VideoError: LocalizedError {
    case noKey, server(String), noVideo
    var errorDescription: String? {
        switch self {
        case .noKey: return "Add your fal.ai key first."
        case .server(let s): return s
        case .noVideo: return "The server finished but returned no video."
        }
    }
}

@MainActor
final class VideoService: ObservableObject {
    static let shared = VideoService()

    @Published var status: String = ""
    @Published var isRunning = false
    @Published var lastVideo: GalleryItem?
    @Published var error: String?
    @Published var apiKey: String = Keychain.get("falKey") {
        didSet { Keychain.set(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), for: "falKey") }
    }
    @Published var customModelID: String = UserDefaults.standard.string(forKey: "customVideoModel") ?? "" {
        didSet { UserDefaults.standard.set(customModelID, forKey: "customVideoModel") }
    }

    private var cancelled = false

    func cancel() { cancelled = true; status = "Cancelling…" }

    func generate(modelID: String, prompt: String, negative: String, image: UIImage?, resolution: String) {
        guard !isRunning else { return }
        error = nil
        cancelled = false
        isRunning = true
        status = "Sending…"
        Task {
            do {
                let url = try await run(modelID: modelID, prompt: prompt, negative: negative, image: image, resolution: resolution)
                status = "Downloading video…"
                let (tmp, _) = try await URLSession.shared.download(from: url)
                let dest = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".mp4")
                try FileManager.default.moveItem(at: tmp, to: dest)
                lastVideo = GalleryStore.shared.add(videoAt: dest, prompt: prompt, model: modelID)
                status = "Done"
            } catch {
                self.error = error.localizedDescription
                status = ""
            }
            isRunning = false
        }
    }

    private func request(_ url: URL, method: String = "GET", body: [String: Any]? = nil) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Key \(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 120
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let msg = (json["detail"] as? String) ?? (json["detail"].map { "\($0)" }) ?? String(data: data, encoding: .utf8) ?? ""
            throw VideoError.server("fal.ai error \(http.statusCode): \(msg.prefix(300))")
        }
        return json
    }

    private func run(modelID: String, prompt: String, negative: String, image: UIImage?, resolution: String) async throws -> URL {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw VideoError.noKey }
        var body: [String: Any] = [
            "prompt": prompt,
            "enable_safety_checker": false,
            "enable_prompt_expansion": false,
            "resolution": resolution
        ]
        if !negative.isEmpty { body["negative_prompt"] = negative }
        if let image, let jpg = image.jpegData(compressionQuality: 0.9) {
            body["image_url"] = "data:image/jpeg;base64," + jpg.base64EncodedString()
        }
        let submitURL = URL(string: "https://queue.fal.run/\(modelID)")!
        let submitted = try await request(submitURL, method: "POST", body: body)
        guard let statusURL = (submitted["status_url"] as? String).flatMap(URL.init(string:)),
              let responseURL = (submitted["response_url"] as? String).flatMap(URL.init(string:)) else {
            throw VideoError.server("Unexpected reply from fal.ai")
        }
        let start = Date()
        while true {
            if cancelled {
                if let cancelURL = (submitted["cancel_url"] as? String).flatMap(URL.init(string:)) {
                    _ = try? await request(cancelURL, method: "PUT")
                }
                throw VideoError.server("Cancelled")
            }
            let st = try await request(statusURL)
            let s = st["status"] as? String ?? ""
            let secs = Int(Date().timeIntervalSince(start))
            switch s {
            case "IN_QUEUE":
                let pos = st["queue_position"] as? Int
                status = "Waiting in line\(pos.map { " (#\($0 + 1))" } ?? "")… \(secs)s"
            case "IN_PROGRESS":
                status = "Making your video… \(secs)s"
            case "COMPLETED":
                let result = try await request(responseURL)
                if let video = result["video"] as? [String: Any], let u = (video["url"] as? String).flatMap(URL.init(string:)) { return u }
                if let videos = result["videos"] as? [[String: Any]], let u = (videos.first?["url"] as? String).flatMap(URL.init(string:)) { return u }
                throw VideoError.noVideo
            default:
                status = "Working… \(secs)s"
            }
            try await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }
}
