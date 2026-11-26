import Foundation
import SwiftUI
import UIKit
import ZIPFoundation

struct DownloadState: Equatable {
    var fraction: Double
    var status: String
}

@MainActor
final class ModelStore: ObservableObject {
    static let shared = ModelStore()

    @Published private(set) var custom: [ModelInfo] = []
    @Published private(set) var installedRoots: [String: URL] = [:]
    @Published var downloads: [String: DownloadState] = [:]
    @Published var lastError: String?
    @Published var selectedID: String = UserDefaults.standard.string(forKey: "selectedModelID") ?? "" {
        didSet { UserDefaults.standard.set(selectedID, forKey: "selectedModelID") }
    }

    private var downloaders: [String: FileDownloader] = [:]

    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static var modelsDir: URL { documents.appending(path: "Models", directoryHint: .isDirectory) }
    private var customFile: URL { Self.modelsDir.appending(path: "custom-models.json") }
    private static let rootMarker = ".imagine-root"

    var allModels: [ModelInfo] { ModelCatalog.builtIn + custom }
    var installedModels: [ModelInfo] { allModels.filter { installedRoots[$0.id] != nil } }
    var selectedModel: ModelInfo? {
        installedModels.first(where: { $0.id == selectedID }) ?? installedModels.first
    }

    static var deviceRAMGB: Double { Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824 }

    init() {
        try? FileManager.default.createDirectory(at: Self.modelsDir, withIntermediateDirectories: true)
        var url = Self.modelsDir
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        loadCustom()
        refreshInstalled()
    }

    func dir(for id: String) -> URL { Self.modelsDir.appending(path: id, directoryHint: .isDirectory) }

    func refreshInstalled() {
        var roots: [String: URL] = [:]
        for m in allModels {
            let marker = dir(for: m.id).appending(path: Self.rootMarker)
            if let rel = try? String(contentsOf: marker, encoding: .utf8) {
                let trimmed = rel.trimmingCharacters(in: .whitespacesAndNewlines)
                roots[m.id] = trimmed.isEmpty ? dir(for: m.id) : dir(for: m.id).appending(path: trimmed, directoryHint: .isDirectory)
            }
        }
        installedRoots = roots
    }

    private func loadCustom() {
        if let data = try? Data(contentsOf: customFile),
           let list = try? JSONDecoder().decode([ModelInfo].self, from: data) {
            custom = list
        }
    }

    private func saveCustom() {
        if let data = try? JSONEncoder().encode(custom) { try? data.write(to: customFile) }
    }

    func addCustom(_ m: ModelInfo) {
        custom.removeAll { $0.id == m.id }
        custom.append(m)
        saveCustom()
    }

    func delete(_ m: ModelInfo) {
        try? FileManager.default.removeItem(at: dir(for: m.id))
        try? FileManager.default.removeItem(at: Self.modelsDir.appending(path: m.id + ".zip"))
        if m.isCustom {
            custom.removeAll { $0.id == m.id }
            saveCustom()
        }
        refreshInstalled()
    }

    func cancel(_ m: ModelInfo) {
        downloaders[m.id]?.cancel()
    }

    // MARK: Download

    func download(_ m: ModelInfo) {
        guard downloads[m.id] == nil else { return }
        downloads[m.id] = DownloadState(fraction: 0, status: "Starting…")
        UIApplication.shared.isIdleTimerDisabled = true
        let dl = FileDownloader()
        downloaders[m.id] = dl
        Task {
            do {
                switch m.source {
                case .hfFolder(let repo, let path):
                    try await downloadFolder(m, repo: repo, path: path, dl: dl)
                case .hfZip(let repo, let path):
                    try await downloadZip(m, url: HuggingFace.fileURL(repo: repo, path: path), dl: dl)
                case .url(let s):
                    guard let u = URL(string: s) else { throw URLError(.badURL) }
                    try await downloadZip(m, url: u, dl: dl)
                case .local:
                    break
                }
                refreshInstalled()
                if selectedID.isEmpty || installedRoots[selectedID] == nil { selectedID = m.id }
            } catch {
                if case DownloadError.cancelled = error {} else {
                    lastError = "\(m.name): \(error.localizedDescription)"
                }
            }
            downloads[m.id] = nil
            downloaders[m.id] = nil
            if downloads.isEmpty { UIApplication.shared.isIdleTimerDisabled = false }
        }
    }

    nonisolated static func skip(_ path: String) -> Bool {
        // Never fetch the NSFW safety checker or the ControlNet-only UNet: not needed, saves space.
        path.contains("SafetyChecker.mlmodelc") || path.contains("ControlledUnet") || path.contains("/controlnet/") || path.hasPrefix("controlnet/")
    }

    private func downloadFolder(_ m: ModelInfo, repo: String, path: String, dl: FileDownloader) async throws {
        downloads[m.id] = DownloadState(fraction: 0, status: "Listing files…")
        let files = try await HuggingFace.listFiles(repo: repo, path: path).filter { !Self.skip($0.path) }
        let total = max(files.reduce(Int64(0)) { $0 + ($1.size ?? 0) }, 1)
        let staging = Self.modelsDir.appending(path: m.id + ".partial", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        var done: Int64 = 0
        for (i, f) in files.enumerated() {
            var rel = f.path
            if !path.isEmpty, rel.hasPrefix(path + "/") { rel = String(rel.dropFirst(path.count + 1)) }
            let dest = staging.appending(path: rel)
            let size = f.size ?? 0
            if let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path),
               let existing = attrs[.size] as? Int64, existing == size, size > 0 {
                done += size
                continue
            }
            let base = done
            let label = "File \(i + 1) of \(files.count)"
            try await dl.download(HuggingFace.fileURL(repo: repo, path: f.path), to: dest) { written, _ in
                let frac = Double(base + written) / Double(total)
                Task { @MainActor in
                    self.downloads[m.id] = DownloadState(fraction: frac, status: "\(label) · \(Self.mb(base + written)) of \(Self.mb(total))")
                }
            }
            done += size
        }
        let final = dir(for: m.id)
        try? FileManager.default.removeItem(at: final)
        try FileManager.default.moveItem(at: staging, to: final)
        try markInstalled(m, in: final)
    }

    private func downloadZip(_ m: ModelInfo, url: URL, dl: FileDownloader) async throws {
        let zipURL = Self.modelsDir.appending(path: m.id + ".zip")
        try await dl.download(url, to: zipURL) { written, expected in
            let frac = expected > 0 ? Double(written) / Double(expected) : 0
            Task { @MainActor in
                self.downloads[m.id] = DownloadState(fraction: frac * 0.85, status: "Downloading · \(Self.mb(written))\(expected > 0 ? " of " + Self.mb(expected) : "")")
            }
        }
        try await install(zip: zipURL, as: m, deleteZip: true)
    }

    /// Unzips a model archive (skipping unneeded parts) and marks it installed.
    func install(zip zipURL: URL, as m: ModelInfo, deleteZip: Bool) async throws {
        downloads[m.id] = DownloadState(fraction: 0.85, status: "Unpacking…")
        let final = dir(for: m.id)
        let id = m.id
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            try? fm.removeItem(at: final)
            try fm.createDirectory(at: final, withIntermediateDirectories: true)
            let archive = try Archive(url: zipURL, accessMode: .read)
            let entries = Array(archive)
            var n = 0
            for entry in entries {
                n += 1
                let p = entry.path
                if Self.skip(p) || p.hasPrefix("__MACOSX") || p.contains("..") { continue }
                let dest = final.appending(path: p)
                if entry.type == .directory {
                    try fm.createDirectory(at: dest, withIntermediateDirectories: true)
                    continue
                }
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                _ = try archive.extract(entry, to: dest, skipCRC32: true)
                let frac = 0.85 + 0.15 * Double(n) / Double(max(entries.count, 1))
                await MainActor.run { ModelStore.shared.downloads[id] = DownloadState(fraction: frac, status: "Unpacking…") }
            }
            if deleteZip { try? fm.removeItem(at: zipURL) }
        }.value
        try markInstalled(m, in: final)
    }

    /// Copies a folder of compiled models (from Files) into the app.
    func install(folder: URL, as m: ModelInfo) async throws {
        downloads[m.id] = DownloadState(fraction: 0.5, status: "Copying…")
        let final = dir(for: m.id)
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            try? fm.removeItem(at: final)
            try fm.copyItem(at: folder, to: final)
        }.value
        try markInstalled(m, in: final)
    }

    func finishImport(_ m: ModelInfo) {
        downloads[m.id] = nil
        refreshInstalled()
        if installedRoots[m.id] != nil, selectedID.isEmpty || installedRoots[selectedID] == nil { selectedID = m.id }
    }

    private func markInstalled(_ m: ModelInfo, in dir: URL) throws {
        guard let root = Self.findRoot(in: dir) else {
            throw NSError(domain: "Imagine", code: 1, userInfo: [NSLocalizedDescriptionKey: "No compiled Core ML Stable Diffusion model (Unet.mlmodelc + TextEncoder.mlmodelc + VAEDecoder.mlmodelc) was found in this download."])
        }
        var rel = root.standardizedFileURL.path.replacingOccurrences(of: dir.standardizedFileURL.path, with: "")
        while rel.hasPrefix("/") { rel.removeFirst() }
        try rel.write(to: dir.appending(path: Self.rootMarker), atomically: true, encoding: .utf8)
        // Fill in model facts for custom models now that the files are here.
        if m.isCustom {
            var updated = m
            updated.isXL = FileManager.default.fileExists(atPath: root.appending(path: "TextEncoder2.mlmodelc").path)
            let lower = root.path.lowercased()
            if lower.contains("original") { updated.attention = .original }
            if lower.contains("split") { updated.attention = .splitEinsum }
            if let size = try? Self.folderSize(dir) { updated.sizeMB = Int(size / 1_000_000) }
            addCustom(updated)
        }
    }

    nonisolated static func findRoot(in dir: URL) -> URL? {
        let fm = FileManager.default
        func ok(_ u: URL) -> Bool {
            let hasUnet = fm.fileExists(atPath: u.appending(path: "Unet.mlmodelc").path) || fm.fileExists(atPath: u.appending(path: "UnetChunk1.mlmodelc").path)
            let hasDecoder = fm.fileExists(atPath: u.appending(path: "VAEDecoder.mlmodelc").path)
            let hasVocab = fm.fileExists(atPath: u.appending(path: "vocab.json").path)
            return hasUnet && hasDecoder && hasVocab
        }
        if ok(dir) { return dir }
        guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { return nil }
        for case let u as URL in en {
            if u.pathExtension == "mlmodelc" { en.skipDescendants(); continue }
            if (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true, ok(u) { return u }
        }
        return nil
    }

    nonisolated static func folderSize(_ dir: URL) throws -> Int64 {
        var total: Int64 = 0
        let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey])
        while let u = en?.nextObject() as? URL {
            total += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    nonisolated static func mb(_ bytes: Int64) -> String {
        let m = Double(bytes) / 1_000_000
        return m >= 1000 ? String(format: "%.2f GB", m / 1000) : String(format: "%.0f MB", m)
    }

    /// Output size the model was compiled for, read from the VAE decoder's metadata.
    nonisolated static func outputSize(root: URL) -> CGSize? {
        let meta = root.appending(path: "VAEDecoder.mlmodelc/metadata.json")
        guard let data = try? Data(contentsOf: meta),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let inputs = arr.first?["inputSchema"] as? [[String: Any]],
              let shape = inputs.first?["shape"] as? String else { return nil }
        let nums = shape.components(separatedBy: CharacterSet(charactersIn: "[], ")).compactMap { Int($0) }
        guard nums.count == 4 else { return nil }
        return CGSize(width: nums[3] * 8, height: nums[2] * 8)
    }

    nonisolated static func hasEncoder(root: URL) -> Bool {
        FileManager.default.fileExists(atPath: root.appending(path: "VAEEncoder.mlmodelc").path)
    }
}
