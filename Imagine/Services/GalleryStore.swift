import Foundation
import UIKit

struct GalleryItem: Identifiable, Codable, Hashable {
    enum Kind: String, Codable { case image, video }
    var id: UUID = UUID()
    var kind: Kind
    var file: String
    var prompt: String
    var negativePrompt: String = ""
    var seed: UInt32 = 0
    var steps: Int = 0
    var guidance: Float = 0
    var model: String = ""
    var date: Date = Date()
}

@MainActor
final class GalleryStore: ObservableObject {
    static let shared = GalleryStore()
    @Published private(set) var items: [GalleryItem] = []

    static var dir: URL { ModelStore.documents.appending(path: "Gallery", directoryHint: .isDirectory) }
    private var indexURL: URL { Self.dir.appending(path: "gallery.json") }

    init() {
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL),
           let list = try? JSONDecoder().decode([GalleryItem].self, from: data) {
            items = list.filter { FileManager.default.fileExists(atPath: Self.dir.appending(path: $0.file).path) }
        }
    }

    func url(_ item: GalleryItem) -> URL { Self.dir.appending(path: item.file) }

    func image(_ item: GalleryItem) -> UIImage? { UIImage(contentsOfFile: url(item).path) }

    private func save() {
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: indexURL, options: .atomic) }
    }

    @discardableResult
    func add(image: UIImage, prompt: String, negative: String, seed: UInt32, steps: Int, guidance: Float, model: String) -> GalleryItem? {
        guard let png = image.pngData() else { return nil }
        let id = UUID()
        let name = id.uuidString + ".png"
        do { try png.write(to: Self.dir.appending(path: name)) } catch { return nil }
        let item = GalleryItem(id: id, kind: .image, file: name, prompt: prompt, negativePrompt: negative, seed: seed, steps: steps, guidance: guidance, model: model)
        items.insert(item, at: 0)
        save()
        return item
    }

    @discardableResult
    func add(videoAt tmp: URL, prompt: String, model: String) -> GalleryItem? {
        let id = UUID()
        let name = id.uuidString + ".mp4"
        do { try FileManager.default.moveItem(at: tmp, to: Self.dir.appending(path: name)) } catch { return nil }
        let item = GalleryItem(id: id, kind: .video, file: name, prompt: prompt, model: model)
        items.insert(item, at: 0)
        save()
        return item
    }

    /// Saves bytes from an online service as-is (JPEG/PNG/WebP image or MP4 video).
    @discardableResult
    func add(data: Data, ext: String, kind: GalleryItem.Kind, prompt: String, negative: String, seed: UInt32, model: String) -> GalleryItem? {
        let id = UUID()
        let safeExt = ext.isEmpty ? (kind == .video ? "mp4" : "png") : ext.lowercased()
        let name = id.uuidString + "." + safeExt
        do { try data.write(to: Self.dir.appending(path: name)) } catch { return nil }
        let item = GalleryItem(id: id, kind: kind, file: name, prompt: prompt, negativePrompt: negative, seed: seed, model: model)
        items.insert(item, at: 0)
        save()
        return item
    }

    func delete(_ item: GalleryItem) {
        try? FileManager.default.removeItem(at: url(item))
        items.removeAll { $0.id == item.id }
        save()
    }
}
