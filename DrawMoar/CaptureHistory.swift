import AVFoundation
import CompanionKit
import PencilKit
import UIKit

struct VoiceRecording: Codable, Equatable {
    let file: String
    let start: Double
    let duration: Double
}

struct VoiceTimeline: Codable, Equatable {
    let sessionStart: Date
    var recordings: [VoiceRecording]
    var note: Note
}

struct CaptureEntry: Identifiable {
    let id: String
    let date: Date
    let image: UIImage
    let drawing: PKDrawing
    let crop: CGRect?
    let windows: [WindowFrame]
    var imported: Bool = false
    var timeline: VoiceTimeline?
}

struct HistoryEntry: Identifiable {
    let id: String
    let date: Date
    let crop: CGRect?
    let windows: [WindowFrame]
    var thumbnail: UIImage?
    var imported: Bool = false
    var hasTimeline: Bool = false
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
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasSuffix(".timeline.json") }
        return try urls.map { url in
            let metadata = try JSONDecoder().decode(Metadata.self, from: Data(contentsOf: url))
            let thumbnail = UIImage(contentsOfFile: thumbnailURL(metadata.id).path)
            return HistoryEntry(id: metadata.id, date: metadata.date, crop: metadata.crop, windows: metadata.windows ?? [], thumbnail: thumbnail, imported: metadata.imported ?? false, hasTimeline: files.fileExists(atPath: timelineURL(metadata.id).path))
        }.sorted { $0.date > $1.date }
    }

    func loadCapture(_ entry: HistoryEntry) throws -> CaptureEntry {
        let data = try Data(contentsOf: directory.appendingPathComponent(entry.id + ".png"))
        guard let image = UIImage(data: data) else { throw ImageRenderer.RenderError.invalidImage }
        let drawing = try PKDrawing(data: Data(contentsOf: directory.appendingPathComponent(entry.id + ".drawing")))
        return CaptureEntry(id: entry.id, date: entry.date, image: image, drawing: drawing, crop: entry.crop, windows: entry.windows, imported: entry.imported, timeline: loadTimeline(entry.id))
    }

    private func thumbnailURL(_ id: String) -> URL {
        directory.appendingPathComponent(id + ".thumbnail")
    }

    private func timelineURL(_ id: String) -> URL {
        directory.appendingPathComponent(id + ".timeline.json")
    }

    func loadTimeline(_ id: String) -> VoiceTimeline? {
        guard let data = try? Data(contentsOf: timelineURL(id)) else { return nil }
        return try? JSONDecoder().decode(VoiceTimeline.self, from: data)
    }

    func saveTimeline(_ timeline: VoiceTimeline, id: String) throws {
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(timeline).write(to: timelineURL(id), options: .atomic)
    }

    func voiceFileName(id: String, number: Int) -> String {
        "\(id).voice-\(number).m4a"
    }

    func saveVoice(_ samples: [Float], id: String, number: Int) throws -> String {
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = voiceFileName(id: id, number: number)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { throw ImageRenderer.RenderError.encoding }
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1]
        let target = directory.appendingPathComponent(name)
        let partial = directory.appendingPathComponent(id + ".voice-\(number).partial.m4a")
        try? files.removeItem(at: partial)
        do {
            let file = try AVAudioFile(forWriting: partial, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        }
        if files.fileExists(atPath: target.path) {
            try files.removeItem(at: target)
        }
        try files.moveItem(at: partial, to: target)
        return name
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
        return HistoryEntry(id: entry.id, date: entry.date, crop: entry.crop, windows: entry.windows, thumbnail: UIImage(data: thumbnailData), imported: entry.imported, hasTimeline: files.fileExists(atPath: timelineURL(entry.id).path))
    }

    func delete(_ id: String) throws {
        guard files.fileExists(atPath: directory.path) else { return }
        for url in try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where url.lastPathComponent.hasPrefix(id + ".") {
            try files.removeItem(at: url)
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
