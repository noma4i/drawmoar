import PencilKit
import UIKit

struct CaptureEntry: Identifiable {
    let id: String
    let date: Date
    let image: UIImage
    let drawing: PKDrawing
    let crop: CGRect?
}

final class CaptureHistory {
    private struct Metadata: Codable {
        let id: String
        let date: Date
        let crop: CGRect?
    }

    private let directory: URL
    private let files = FileManager.default

    init(directory: URL) {
        self.directory = directory
    }

    func load() throws -> [CaptureEntry] {
        guard files.fileExists(atPath: directory.path) else { return [] }
        let urls = try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        return try urls.map { url in
            let metadata = try JSONDecoder().decode(Metadata.self, from: Data(contentsOf: url))
            let imageData = try Data(contentsOf: directory.appendingPathComponent(metadata.id + ".png"))
            guard let image = UIImage(data: imageData) else { throw ImageRenderer.RenderError.invalidImage }
            let drawing = try PKDrawing(data: Data(contentsOf: directory.appendingPathComponent(metadata.id + ".drawing")))
            return CaptureEntry(id: metadata.id, date: metadata.date, image: image, drawing: drawing, crop: metadata.crop)
        }.sorted { $0.date > $1.date }
    }

    func save(_ entry: CaptureEntry) throws {
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let png = entry.image.pngData() else { throw ImageRenderer.RenderError.encoding }
        try png.write(to: directory.appendingPathComponent(entry.id + ".png"), options: .atomic)
        try entry.drawing.dataRepresentation().write(to: directory.appendingPathComponent(entry.id + ".drawing"), options: .atomic)
        let metadata = Metadata(id: entry.id, date: entry.date, crop: entry.crop)
        try JSONEncoder().encode(metadata).write(to: directory.appendingPathComponent(entry.id + ".json"), options: .atomic)
    }

    func delete(_ id: String) throws {
        for suffix in ["json", "png", "drawing"] {
            let url = directory.appendingPathComponent(id + "." + suffix)
            if files.fileExists(atPath: url.path) {
                try files.removeItem(at: url)
            }
        }
    }
}
