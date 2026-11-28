import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One Server-Sent Event from a Gradio `/call` stream.
public struct SSEEvent: Equatable, Sendable {
    public var event: String
    public var data: String
}

public enum SSEParser {
    /// Splits a full or partial SSE text into events. Lines without `event:` default to "message".
    public static func parse(_ text: String) -> [SSEEvent] {
        var out: [SSEEvent] = []
        var event = ""
        var data: [String] = []
        func flush() {
            if !event.isEmpty || !data.isEmpty {
                out.append(SSEEvent(event: event.isEmpty ? "message" : event, data: data.joined(separator: "\n")))
            }
            event = ""; data = []
        }
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if raw.isEmpty { flush(); continue }
            if raw.hasPrefix("event:") { event = raw.dropFirst(6).trimmingCharacters(in: .whitespaces) }
            else if raw.hasPrefix("data:") { data.append(String(raw.dropFirst(5)).trimmingCharacters(in: .whitespaces)) }
        }
        flush()
        return out
    }
}

/// A tiny client for any public Gradio app (Hugging Face Space) using the documented HTTP API:
/// POST {prefix}/call/{api} -> event_id, then GET {prefix}/call/{api}/{event_id} streams SSE.
public struct GradioClient: Sendable {
    public var host: URL           // e.g. https://tongyi-mai-z-image-turbo.hf.space
    public var prefix: String      // "/gradio_api" on Gradio 5/6, "" on Gradio 4
    public var token: String       // optional user HF token (more free GPU time)

    public init(host: URL, prefix: String = "/gradio_api", token: String = "") {
        self.host = host; self.prefix = prefix; self.token = token
    }

    func url(_ path: String) -> URL { URL(string: host.absoluteString + prefix + path)! }

    func request(_ url: URL, method: String = "GET") -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue("Imagine-iOS/2.0", forHTTPHeaderField: "User-Agent")
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { r.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        return r
    }

    /// Uploads a file and returns a Gradio FileData dictionary to pass as an input.
    public func upload(_ data: Data, filename: String = "input.jpg", mime: String = "image/jpeg") async throws -> [String: Any] {
        var r = request(url("/upload"), method: "POST")
        let boundary = "imagine-\(UUID().uuidString)"
        r.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        r.httpBody = HTTP.multipart(field: "files", filename: filename, mime: mime, data: data, boundary: boundary)
        let (body, code, _) = try await HTTP.send(r)
        guard (200..<300).contains(code), let paths = HTTP.json(body) as? [String], let p = paths.first else {
            throw GenError.http(code, "upload failed: \(HTTP.snippet(body))")
        }
        return ["path": p, "meta": ["_type": "gradio.FileData"], "orig_name": filename]
    }

    /// Runs one prediction and returns the decoded `data` array of the `complete` event.
    public func call(_ api: String, data: [Any], status: StatusHandler? = nil) async throws -> [Any] {
        var r = request(url("/call/\(api)"), method: "POST")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: ["data": data])
        let (body, code, _) = try await HTTP.send(r)
        guard (200..<300).contains(code), let obj = HTTP.json(body) as? [String: Any], let id = obj["event_id"] as? String else {
            throw GenError.http(code, HTTP.snippet(body))
        }
        status?(.queued(position: nil, eta: nil))
        let streamURL = url("/call/\(api)/\(id)")
        return try await readStream(request(streamURL), status: status)
    }

    func readStream(_ req: URLRequest, status: StatusHandler?) async throws -> [Any] {
        #if canImport(FoundationNetworking)
        let (body, code, _) = try await HTTP.send(req)
        guard (200..<300).contains(code) else { throw GenError.http(code, HTTP.snippet(body)) }
        let events = SSEParser.parse(String(decoding: body, as: UTF8.self))
        for e in events { if let d = try Self.handle(e, status: status) { return d } }
        throw GenError.server("The Space closed the connection without a result.")
        #else
        let (bytes, resp) = try await HTTP.session.bytes(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw GenError.http(code, "stream failed") }
        var event = ""
        var dataLines: [String] = []
        for try await line in bytes.lines {
            if Task.isCancelled { throw GenError.cancelled }
            if line.hasPrefix("event:") {
                // A new event starts; flush the previous one if it had data.
                if !dataLines.isEmpty {
                    if let d = try Self.handle(SSEEvent(event: event, data: dataLines.joined(separator: "\n")), status: status) { return d }
                    dataLines = []
                }
                event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
                // Gradio sends single-line data, so handle immediately.
                if let d = try Self.handle(SSEEvent(event: event, data: dataLines.joined(separator: "\n")), status: status) { return d }
                dataLines = []
            }
        }
        throw GenError.server("The Space closed the connection without a result.")
        #endif
    }

    /// Returns the result for `complete`, throws for `error`, reports progress otherwise.
    static func handle(_ e: SSEEvent, status: StatusHandler?) throws -> [Any]? {
        switch e.event {
        case "complete":
            guard let arr = HTTP.json(Data(e.data.utf8)) as? [Any] else { throw GenError.server("Unreadable result from the Space.") }
            return arr
        case "error":
            let msg = (e.data == "null" || e.data.isEmpty) ? "" : e.data.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if msg.lowercased().contains("quota") { throw GenError.rateLimited(msg) }
            throw GenError.server(msg.isEmpty ? "The Space is busy, out of free GPU time, or failed." : msg)
        case "heartbeat":
            return nil
        default:
            if let obj = HTTP.json(Data(e.data.utf8)) as? [String: Any] {
                if let rank = obj["rank"] as? Int { status?(.queued(position: rank + 1, eta: obj["rank_eta"] as? Double)) }
                else if let p = obj["progress_data"] as? [[String: Any]], let f = p.first,
                        let i = f["index"] as? Int, let l = f["length"] as? Int { status?(.working("Step \(i + 1) of \(l)")) }
            } else {
                status?(.working("Generating…"))
            }
            return nil
        }
    }

    /// Finds the first output file (image or video) URL in a Gradio result.
    public func firstFileURL(in value: Any) -> URL? {
        Self.firstFileURL(in: value, host: host, prefix: prefix)
    }

    public static func firstFileURL(in value: Any, host: URL, prefix: String) -> URL? {
        if let d = value as? [String: Any] {
            if let u = d["url"] as? String, u.hasPrefix("http"), let url = URL(string: u) { return url }
            if let p = d["path"] as? String, d["meta"] != nil || d["orig_name"] != nil || d["mime_type"] != nil {
                return URL(string: host.absoluteString + prefix + "/file=" + p)
            }
            for key in ["video", "image", "value"] { if let v = d[key], let u = firstFileURL(in: v, host: host, prefix: prefix) { return u } }
            for (_, v) in d { if let u = firstFileURL(in: v, host: host, prefix: prefix) { return u } }
        } else if let a = value as? [Any] {
            for v in a { if let u = firstFileURL(in: v, host: host, prefix: prefix) { return u } }
        } else if let s = value as? String, s.hasPrefix("http"), let u = URL(string: s) {
            return u
        }
        return nil
    }

    public func download(_ url: URL) async throws -> Data {
        let (data, code, _) = try await HTTP.send(request(url))
        guard (200..<300).contains(code), !data.isEmpty else { throw GenError.http(code, "download failed") }
        return data
    }
}
