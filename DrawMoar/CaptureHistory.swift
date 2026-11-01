import CompanionKit
import PencilKit
import UIKit

struct CaptureEntry: Identifiable {
    let id: String
    let date: Date
    let image: UIImage
    let drawing: PKDrawing
    let crop: CGRect?
    let windows: [WindowFrame]
    var imported: Bool = false
}

struct HistoryEntry: Identifiable {
    let id: String
    let date: Date
    let crop: CGRect?
    let windows: [WindowFrame]
    var thumbnail: UIImage?
    var imported: Bool = false
}

final class CaptureHistory {
    private struct Metadata: Codable {
        let id: String
        let date: Date
        let crop: CGRect?
        let windows: [WindowFrame]?
        let imported: Bool?
    }

    private let directory: URL
    private let files = FileManager.default

    init(directory: URL) {
        self.directory = directory
    }

    func load() throws -> [HistoryEntry] {
        guard files.fileExists(atPath: directory.path) else { return [] }
        let urls = try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        return try urls.map { url in
            let metadata = try JSONDecoder().decode(Metadata.self, from: Data(contentsOf: url))
            let thumbnail = UIImage(contentsOfFile: thumbnailURL(metadata.id).path)
            return HistoryEntry(id: metadata.id, date: metadata.date, crop: metadata.crop, windows: metadata.windows ?? [], thumbnail: thumbnail, imported: metadata.imported ?? false)
        }.sorted { $0.date > $1.date }
    }

    func loadCapture(_ entry: HistoryEntry) throws -> CaptureEntry {
        let data = try Data(contentsOf: directory.appendingPathComponent(entry.id + ".png"))
        guard let image = UIImage(data: data) else { throw ImageRenderer.RenderError.invalidImage }
        let drawing = try PKDrawing(data: Data(contentsOf: directory.appendingPathComponent(entry.id + ".drawing")))
        return CaptureEntry(id: entry.id, date: entry.date, image: image, drawing: drawing, crop: entry.crop, windows: entry.windows, imported: entry.imported)
    }

    private func thumbnailURL(_ id: String) -> URL {
        directory.appendingPathComponent(id + ".thumbnail")
    }

    func saveThumbnail(_ data: Data, id: String) throws {
        try data.write(to: thumbnailURL(id), options: .atomic)
    }

    func save(_ entry: CaptureEntry) throws -> HistoryEntry {
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let png = entry.image.pngData() else { throw ImageRenderer.RenderError.encoding }
        try png.write(to: directory.appendingPathComponent(entry.id + ".png"), options: .atomic)
        try entry.drawing.dataRepresentation().write(to: directory.appendingPathComponent(entry.id + ".drawing"), options: .atomic)
        let thumbnailData = try ImageRenderer.thumbnail(image: entry.image, drawing: entry.drawing, crop: entry.crop)
        try saveThumbnail(thumbnailData, id: entry.id)
        let metadata = Metadata(id: entry.id, date: entry.date, crop: entry.crop, windows: entry.windows, imported: entry.imported)
        try JSONEncoder().encode(metadata).write(to: directory.appendingPathComponent(entry.id + ".json"), options: .atomic)
        return HistoryEntry(id: entry.id, date: entry.date, crop: entry.crop, windows: entry.windows, thumbnail: UIImage(data: thumbnailData), imported: entry.imported)
    }

    func delete(_ id: String) throws {
        for suffix in ["json", "png", "drawing", "thumbnail"] {
            let url = directory.appendingPathComponent(id + "." + suffix)
            if files.fileExists(atPath: url.path) {
                try files.removeItem(at: url)
            }
        }
    }

    func size() throws -> Int64 {
        guard files.fileExists(atPath: directory.path) else { return 0 }
        let urls = files.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
        var total: Int64 = 0
        while let url = urls?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }

    func deleteAll() throws {
        guard files.fileExists(atPath: directory.path) else { return }
        for url in try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            try files.removeItem(at: url)
        }
    }
}
