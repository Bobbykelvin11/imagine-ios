import Foundation

struct HFFile: Decodable {
    let type: String
    let path: String
    let size: Int64?
}

struct HFModelSummary: Decodable, Identifiable {
    let id: String
    let downloads: Int?
    let likes: Int?
}

enum HuggingFace {
    static func fileURL(repo: String, path: String) -> URL {
        let escaped = path.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
        return URL(string: "https://huggingface.co/\(repo)/resolve/main/\(escaped)")!
    }

    static func listFiles(repo: String, path: String) async throws -> [HFFile] {
        var s = "https://huggingface.co/api/models/\(repo)/tree/main"
        if !path.isEmpty {
            s += "/" + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path)
        }
        s += "?recursive=true"
        guard let url = URL(string: s) else { throw URLError(.badURL) }
        let (data, resp) = try await URLSession.shared.data(from: url)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw DownloadError.http(http.statusCode, s)
        }
        return try JSONDecoder().decode([HFFile].self, from: data).filter { $0.type == "file" }
    }

    static func search(_ query: String) async throws -> [HFModelSummary] {
        var comps = URLComponents(string: "https://huggingface.co/api/models")!
        comps.queryItems = [
            URLQueryItem(name: "filter", value: "coreml"),
            URLQueryItem(name: "search", value: query),
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "limit", value: "40")
        ]
        let (data, _) = try await URLSession.shared.data(from: comps.url!)
        return try JSONDecoder().decode([HFModelSummary].self, from: data)
    }

    struct Candidate: Identifiable, Hashable {
        var id: String { kind + ":" + path }
        let kind: String   // "zip" or "folder"
        let path: String
        let sizeMB: Int
        var label: String {
            let name = path.isEmpty ? "(repo root)" : path
            return "\(name) · \(sizeMB >= 1000 ? String(format: "%.1f GB", Double(sizeMB) / 1000) : "\(sizeMB) MB")"
        }
    }

    /// Finds downloadable Core ML Stable Diffusion variants in a repo: zips and compiled folders.
    static func candidates(repo: String) async throws -> [Candidate] {
        let files = try await listFiles(repo: repo, path: "")
        var out: [Candidate] = []
        for f in files where f.path.lowercased().hasSuffix(".zip") {
            out.append(Candidate(kind: "zip", path: f.path, sizeMB: Int((f.size ?? 0) / 1_000_000)))
        }
        // Folders that directly contain a compiled Unet.
        var folderSizes: [String: Int64] = [:]
        var roots = Set<String>()
        for f in files {
            let comps = f.path.split(separator: "/").map(String.init)
            if let idx = comps.firstIndex(where: { $0 == "Unet.mlmodelc" || $0 == "UnetChunk1.mlmodelc" }) {
                roots.insert(comps[0..<idx].joined(separator: "/"))
            }
        }
        for f in files {
            for r in roots where (r.isEmpty || f.path.hasPrefix(r + "/")) && !f.path.lowercased().hasSuffix(".zip") {
                folderSizes[r, default: 0] += f.size ?? 0
            }
        }
        for r in roots.sorted() {
            out.append(Candidate(kind: "folder", path: r, sizeMB: Int((folderSizes[r] ?? 0) / 1_000_000)))
        }
        return out
    }
}
