import ImageIO
import UIKit

struct SharedInbox {
    private let directory: URL?

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else if let group = Bundle.main.object(forInfoDictionaryKey: "DrawMoarAppGroup") as? String {
            self.directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?.appendingPathComponent("Inbox", isDirectory: true)
        } else {
            self.directory = nil
        }
    }

    func takeNewest() -> UIImage? {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles),
              let newest = files.max(by: { date($0) < date($1) }) else { return nil }
        defer { files.forEach { try? FileManager.default.removeItem(at: $0) } }
        guard let source = CGImageSourceCreateWithURL(newest as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 4096,
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    private func date(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}
