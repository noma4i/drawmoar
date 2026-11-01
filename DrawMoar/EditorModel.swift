import CompanionKit
import Observation
import PencilKit
import UIKit

@MainActor @Observable final class EditorModel {
    var image: UIImage?
    var drawing = PKDrawing()
    var crop: CGRect?
    var displays: [DisplayInfo] = []
    var selectedDisplay: UInt32?
    var error: String?
    var busy = false
    var copied = 0
    let client: any MacCapturing

    init(client: any MacCapturing) {
        self.client = client
    }

    func activate() async {
        guard drawing.strokes.isEmpty, crop == nil, !busy else { return }
        await refresh()
    }

    func refresh() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let data = try await client.capture(displayId: selectedDisplay)
            guard let image = UIImage(data: data) else { throw MacError.unexpected }
            self.image = image
            error = nil
            do { displays = try await client.displays() } catch { self.error = error.localizedDescription }
        } catch { self.error = error.localizedDescription }
    }

    func newCapture() async {
        drawing = PKDrawing()
        crop = nil
        await refresh()
    }

    func copy() async {
        guard let image, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let data = try ImageRenderer.png(image: image, drawing: drawing, crop: crop)
            try await client.paste(data)
            copied += 1
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}
