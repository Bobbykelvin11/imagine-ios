import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Aspect ratios offered in the prompt bar (like Grok Imagine).
public enum AspectRatio: String, CaseIterable, Codable, Identifiable, Sendable {
    case square = "1:1"
    case portrait = "2:3"
    case landscape = "3:2"
    case tall = "9:16"
    case wide = "16:9"
    case photo = "3:4"
    case photoWide = "4:3"

    public var id: String { rawValue }

    public var ratio: Double {
        let p = rawValue.split(separator: ":").compactMap { Double($0) }
        return p[0] / p[1]
    }

    /// Size rounded to a multiple of `multiple`, keeping roughly `pixels` total.
    public func size(pixels: Double = 1024 * 1024, multiple: Int = 32, maxSide: Int = 2048) -> (width: Int, height: Int) {
        let h = (pixels / ratio).squareRoot()
        let w = h * ratio
        func snap(_ v: Double) -> Int { max(multiple, min(maxSide, Int((v / Double(multiple)).rounded()) * multiple)) }
        return (snap(w), snap(h))
    }

    /// Z-Image Turbo only accepts these exact dropdown values (1024 tier).
    public var zImageResolution: String {
        switch self {
        case .square: return "1024x1024 ( 1:1 )"
        case .portrait: return "832x1248 ( 2:3 )"
        case .landscape: return "1248x832 ( 3:2 )"
        case .tall: return "720x1280 ( 9:16 )"
        case .wide: return "1280x720 ( 16:9 )"
        case .photo: return "864x1152 ( 3:4 )"
        case .photoWide: return "1152x864 ( 4:3 )"
        }
    }
}

public enum MediaKind: String, Codable, Sendable { case image, video }

public struct GenRequest: Sendable {
    public var prompt: String
    public var negative: String = ""
    public var aspect: AspectRatio = .square
    public var seed: Int = Int.random(in: 0...2_147_483_647)
    /// JPEG/PNG bytes of a photo to edit (image) or animate (video).
    public var inputImage: Data? = nil
    /// 0...1, how much the photo may change (img2img backends).
    public var strength: Double = 0.65
    /// Video length in seconds.
    public var duration: Double = 3
    public init(prompt: String) { self.prompt = prompt }
}

public struct GenOutput: Sendable {
    public var data: Data
    public var fileExtension: String
    public var seed: Int?
    public var provider: String
}

public enum GenStatus: Sendable, Equatable {
    case starting(String)
    case queued(position: Int?, eta: Double?)
    case working(String)
}

public typealias StatusHandler = @Sendable (GenStatus) -> Void

public enum GenError: LocalizedError, Equatable {
    case unsupported(String)
    case http(Int, String)
    case server(String)
    case noOutput(String)
    case rateLimited(String)
    case notConfigured(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .unsupported(let s): return s
        case .http(let c, let s): return "Server error \(c)\(s.isEmpty ? "" : ": \(s)")"
        case .server(let s): return s
        case .noOutput(let s): return "\(s) finished but sent nothing back."
        case .rateLimited(let s): return s
        case .notConfigured(let s): return s
        case .cancelled: return "Cancelled"
        }
    }
}

/// Settings every provider can read. Keys are the user's own and optional.
public struct ProviderSettings: Codable, Sendable, Equatable {
    public var hfToken: String = ""
    public var pollinationsKey: String = ""
    public var hordeKey: String = ""
    public var a1111URL: String = ""
    public var comfyURL: String = ""
    public var comfyImageWorkflow: String = ComfyUI.defaultImageWorkflow
    public var comfyVideoWorkflow: String = ""
    public var comfyCheckpoint: String = "flux1-schnell-fp8.safetensors"
    public init() {}
}

enum HTTP {
    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 300
        c.timeoutIntervalForResource = 900
        return URLSession(configuration: c)
    }()

    static func send(_ req: URLRequest) async throws -> (Data, Int, [String: String]) {
        let (data, resp) = try await session.data(for: req)
        let http = resp as? HTTPURLResponse
        var headers: [String: String] = [:]
        for (k, v) in http?.allHeaderFields ?? [:] { headers[String(describing: k).lowercased()] = String(describing: v) }
        return (data, http?.statusCode ?? 0, headers)
    }

    static func json(_ data: Data) -> Any? { try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }

    static func snippet(_ data: Data) -> String {
        if let obj = json(data) as? [String: Any] {
            if let e = obj["error"] as? [String: Any], let m = e["message"] as? String { return m }
            if let m = obj["message"] as? String { return m }
            if let m = obj["error"] as? String { return m }
            if let m = obj["detail"] as? String { return m }
        }
        return String(String(decoding: data.prefix(300), as: UTF8.self))
    }

    static func multipart(field: String, filename: String, mime: String, data: Data, boundary: String) -> Data {
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(field)\"; filename=\"\(filename)\"\r\n".utf8))
        body.append(Data("Content-Type: \(mime)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    /// Guesses a file extension from magic bytes.
    static func sniffExtension(_ data: Data, fallback: String) -> String {
        let b = [UInt8](data.prefix(12))
        if b.count >= 3, b[0] == 0xFF, b[1] == 0xD8 { return "jpg" }
        if b.count >= 4, b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return "png" }
        if b.count >= 12, b[0] == 0x52, b[1] == 0x49, b[8] == 0x57, b[9] == 0x45 { return "webp" }
        if b.count >= 3, b[0] == 0x47, b[1] == 0x49, b[2] == 0x46 { return "gif" }
        if b.count >= 8, b[4] == 0x66, b[5] == 0x74, b[6] == 0x79, b[7] == 0x70 { return "mp4" }
        if b.count >= 4, b[0] == 0x1A, b[1] == 0x45, b[2] == 0xDF, b[3] == 0xA3 { return "webm" }
        return fallback
    }
}
