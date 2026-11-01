import CompanionKit
import Observation
import PencilKit
import UIKit

@MainActor @Observable final class EditorModel {
    var image: UIImage?
    private var session = UUID().uuidString
    var drawing = PKDrawing() {
        didSet {
            if drawing != oldValue {
                edited()
            }
        }
    }

    var crop: CGRect? {
        didSet {
            if crop != oldValue {
                edited()
            }
        }
    }

    var displays: [DisplayInfo] = []
    var displayError: String?
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
    private(set) var sendError: String?
    private(set) var delivered = false
    private(set) var lineWidth: CGFloat
    static let lineWidths: [CGFloat] = [4, 8, 16, 32]
    var copied = 0
    var client: (any MacCapturing)?
    var pairing: Pairing?
    private let defaults: UserDefaults
    private let deletePairing: () throws -> Void
    private let delay: () async throws -> Void
    private var debounce: Task<Void, Never>?
    private var revision = 0
    private var readyRevision: Int?
    private var resetting = false

    init(client: (any MacCapturing)?, pairing: Pairing? = nil, defaults: UserDefaults = .standard, deletePairing: @escaping () throws -> Void = PairingStore.delete, delay: @escaping () async throws -> Void = { try await Task.sleep(for: .milliseconds(500)) }) {
        self.client = client
        self.pairing = pairing
        self.defaults = defaults
        self.deletePairing = deletePairing
        self.delay = delay
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
        let range = tool.inkType.validWidthRange
        return PKInkingTool(tool.inkType, color: tool.color, width: min(max(width * scale, range.lowerBound), range.upperBound))
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

    func loadDisplays() async {
        guard let client else { return }
        do {
            displays = try await client.displays()
            displayError = nil
        } catch { displayError = error.localizedDescription }
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
            revision += 1
            debounce?.cancel()
            readyRevision = nil
            delivered = false
            sendError = nil
            error = nil
            do { displays = try await client.displays() } catch { self.error = error.localizedDescription }
        } catch { self.error = error.localizedDescription }
    }

    func newCapture() async {
        resetting = true
        drawing = PKDrawing()
        crop = nil
        resetting = false
        revision += 1
        debounce?.cancel()
        readyRevision = nil
        delivered = false
        await refresh()
    }

    private func edited() {
        guard !resetting, image != nil else { return }
        revision += 1
        let next = revision
        delivered = false
        sendError = nil
        readyRevision = nil
        debounce?.cancel()
        debounce = Task {
            do { try await delay() } catch { return }
            guard !Task.isCancelled, revision == next else { return }
            readyRevision = next
            Task { await sendIfReady() }
        }
    }

    private func sendIfReady() async {
        guard !sending, let current = readyRevision, let image, let client else { return }
        readyRevision = nil
        let currentSession = session
        sending = true
        do {
            let data = try ImageRenderer.png(image: image, drawing: drawing, crop: crop)
            try await client.paste(data, session: currentSession)
            copied += 1
            if revision == current {
                delivered = true; sendError = nil
            }
        } catch {
            if revision == current {
                sendError = error.localizedDescription
            }
        }
        sending = false
        if readyRevision != nil {
            await sendIfReady()
        }
    }
}
