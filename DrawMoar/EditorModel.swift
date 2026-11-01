import CompanionKit
import Observation
import PencilKit
import UIKit

@MainActor @Observable final class EditorModel {
    var image: UIImage?
    private var session = UUID().uuidString
    var drawing = PKDrawing()
    var crop: CGRect?
    var displays: [DisplayInfo] = []
    var selectedDisplay: UInt32? {
        didSet {
            if let selectedDisplay {
                defaults.set(Int(selectedDisplay), forKey: "displayId")
            } else {
                defaults.removeObject(forKey: "displayId")
            }
        }
    }

    var error: String?
    var busy = false
    var sending = false
    private(set) var lineWidth: CGFloat
    static let lineWidths: [CGFloat] = [4, 8, 16, 32]
    var copied = 0
    var client: (any MacCapturing)?
    var pairing: Pairing?
    private let defaults: UserDefaults
    private let deletePairing: () throws -> Void

    init(client: (any MacCapturing)?, pairing: Pairing? = nil, defaults: UserDefaults = .standard, deletePairing: @escaping () throws -> Void = PairingStore.delete) {
        self.client = client
        self.pairing = pairing
        self.defaults = defaults
        self.deletePairing = deletePairing
        let savedWidth = CGFloat(defaults.double(forKey: "lineWidth"))
        lineWidth = Self.lineWidths.contains(savedWidth) ? savedWidth : Self.lineWidths[1]
        if let value = defaults.object(forKey: "displayId") as? Int {
            selectedDisplay = UInt32(exactly: value)
        }
    }

    func setLineWidth(_ width: CGFloat) {
        guard Self.lineWidths.contains(width) else { return }
        lineWidth = width
        defaults.set(Double(width), forKey: "lineWidth")
    }

    nonisolated static func canvasScale(for size: CGSize) -> CGFloat {
        min(1, 2048 / max(size.width, size.height))
    }

    static func inkingTool(_ tool: PKInkingTool, width: CGFloat, scale: CGFloat) -> PKInkingTool {
        PKInkingTool(tool.inkType, color: tool.color, width: width * scale)
    }

    func forgetMac() {
        do {
            try deletePairing()
            pairing = nil
            client = nil
            selectedDisplay = nil
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func setPairing(_ pairing: Pairing, browser: MacBrowser) {
        self.pairing = pairing
        client = MacClient(pairing: pairing, browser: browser)
        selectedDisplay = nil
    }

    func activate() async {
        guard drawing.strokes.isEmpty, crop == nil, !busy else { return }
        await refresh()
    }

    func refresh() async {
        guard !busy, let client else { return }
        busy = true
        defer { busy = false }
        do {
            if selectedDisplay != nil {
                displays = try await client.displays()
                if !displays.contains(where: { $0.id == selectedDisplay }) {
                    selectedDisplay = nil
                }
            }
            let data = try await client.capture(displayId: selectedDisplay)
            guard let image = UIImage(data: data) else { throw MacError.unexpected }
            self.image = image
            session = UUID().uuidString
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
        guard let image, let client, !busy else { return }
        busy = true
        sending = true
        defer { busy = false; sending = false }
        do {
            let data = try ImageRenderer.png(image: image, drawing: drawing, crop: crop)
            try await client.paste(data, session: session)
            copied += 1
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}
