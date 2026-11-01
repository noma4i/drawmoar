import CompanionKit
import Observation
import PencilKit
import UIKit

@MainActor @Observable final class EditorModel {
    var image: UIImage?
    private(set) var windows: [WindowFrame] = []
    private var session = UUID().uuidString
    private var captureDate = Date()
    private(set) var history: [CaptureEntry] = []
    private let storage: CaptureHistory
    private var cropUndo: [CGRect?] = []
    private var windowChain: [WindowFrame] = []
    private var windowDepth = 0
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

    init(client: (any MacCapturing)?, pairing: Pairing? = nil, defaults: UserDefaults = .standard, deletePairing: @escaping () throws -> Void = PairingStore.delete, delay: @escaping () async throws -> Void = { try await Task.sleep(for: .milliseconds(500)) }, historyDirectory: URL? = nil) {
        let directory = historyDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Captures", isDirectory: true)
        storage = CaptureHistory(directory: directory)
        self.client = client
        self.pairing = pairing
        self.defaults = defaults
        self.deletePairing = deletePairing
        self.delay = delay
        let savedWidth = CGFloat(defaults.double(forKey: "lineWidth"))
        lineWidth = Self.lineWidths.contains(savedWidth) ? savedWidth : Self.lineWidths[1]
        do { history = try storage.load() } catch { self.error = error.localizedDescription }
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
            let capture = try await client.capture(displayId: selectedDisplay)
            guard let image = UIImage(data: capture.png) else { throw MacError.unexpected }
            if let current = currentEntry() {
                try save(current)
            }
            resetting = true
            self.image = image
            windows = capture.windows
            drawing = PKDrawing()
            crop = nil
            resetting = false
            session = UUID().uuidString
            captureDate = Date()
            cropUndo = []
            try save(currentEntry()!)
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
        await refresh()
    }

    private func currentEntry() -> CaptureEntry? {
        guard let image else { return nil }
        return CaptureEntry(id: session, date: captureDate, image: image, drawing: drawing, crop: crop, windows: windows)
    }

    private func save(_ entry: CaptureEntry) throws {
        try storage.save(entry)
        history.removeAll { $0.id == entry.id }
        history.append(entry)
        history.sort { $0.date > $1.date }
        while history.count > 30 {
            let removed = history.removeLast()
            try storage.delete(removed.id)
        }
    }

    func select(_ entry: CaptureEntry) async {
        do {
            if let current = currentEntry() {
                try save(current)
            }
            debounce?.cancel()
            revision += 1
            readyRevision = nil
            resetting = true
            image = entry.image
            windows = entry.windows
            drawing = entry.drawing
            crop = entry.crop
            session = entry.id
            captureDate = entry.date
            cropUndo = []
            resetting = false
            delivered = false
            readyRevision = revision
            await sendIfReady()
        } catch { self.error = error.localizedDescription }
    }

    func deleteHistory(_ entry: CaptureEntry) {
        do {
            try storage.delete(entry.id)
            history.removeAll { $0.id == entry.id }
            if entry.id == session {
                debounce?.cancel()
                revision += 1
                readyRevision = nil
                resetting = true
                image = nil
                windows = []
                drawing = PKDrawing()
                crop = nil
                resetting = false
                cropUndo = []
                delivered = false
            }
        } catch { self.error = error.localizedDescription }
    }

    func applyCrop(_ rect: CGRect) {
        guard crop != rect else { return }
        cropUndo.append(crop)
        crop = rect
    }

    func window(at point: CGPoint) -> CGRect? {
        windows.lazy.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
            .first { $0.contains(point) }
    }

    func resetWindowSelection() {
        windowChain = []
        windowDepth = 0
    }

    func selectWindow(at point: CGPoint, confirm: Bool) -> CGRect? {
        var chain: [WindowFrame] = []
        var candidates = windows
        while let frame = candidates.first(where: { windowRect($0).contains(point) }) {
            chain.append(frame)
            candidates = frame.children
        }
        if confirm {
            guard let frame = windowChain.indices.contains(windowDepth) ? windowChain[windowDepth] : chain.first else { return nil }
            let rect = windowRect(frame)
            applyCrop(rect)
            return rect
        }
        guard !chain.isEmpty else {
            resetWindowSelection()
            return nil
        }
        if chain == windowChain {
            windowDepth = (windowDepth + 1) % chain.count
        } else {
            windowChain = chain
            windowDepth = 0
        }
        return windowRect(chain[windowDepth])
    }

    private func windowRect(_ frame: WindowFrame) -> CGRect {
        CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
    }

    func undoCrop() -> Bool {
        guard !cropUndo.isEmpty else { return false }
        crop = cropUndo.removeLast()
        return true
    }

    private func edited() {
        guard !resetting, image != nil else { return }
        if let current = currentEntry() {
            do { try save(current) } catch { self.error = error.localizedDescription }
        }
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
