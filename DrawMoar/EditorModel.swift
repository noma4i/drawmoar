import CompanionKit
import Observation
import PencilKit
import SwiftUI
import UIKit

enum Appearance: String, CaseIterable {
    case system, light, dark

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum Retention: String, CaseIterable {
    case day, week, month, forever

    var interval: TimeInterval? {
        switch self {
        case .day: 86400
        case .week: 7 * 86400
        case .month: 30 * 86400
        case .forever: nil
        }
    }
}

@MainActor @Observable final class EditorModel {
    var image: UIImage?
    private(set) var windows: [WindowFrame] = []
    private var session = UUID().uuidString
    private var captureDate = Date()
    private(set) var imported = false
    private(set) var history: [HistoryEntry] = []
    private let storage: CaptureHistory
    private(set) var storageSize: Int64 = 0
    var retention: Retention {
        didSet { defaults.set(retention.rawValue, forKey: "captureRetention") }
    }

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
    var appearance: Appearance {
        didSet { defaults.set(appearance.rawValue, forKey: "appearance") }
    }

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
    var client: (any MacCapturing)?
    var pairing: Pairing?
    private let defaults: UserDefaults
    private let deletePairing: () throws -> Void
    private let delay: () async throws -> Void
    private let render: (UIImage, PKDrawing, CGRect?) throws -> Data
    private let takeInboxImage: () -> UIImage?
    private let saveCapture: (CaptureHistory, CaptureEntry) throws -> HistoryEntry
    private var debounce: Task<Void, Never>?
    private var revision = 0
    private var readyRevision: Int?
    private var importing = false
    private var resetting = false
    private var usingTool = false
    private var hasPendingSend = false
    private var pendingSave: CaptureEntry?
    private var saveTask: Task<Void, Never>?
    private var historySaveFailed = false

    init(client: (any MacCapturing)?, pairing: Pairing? = nil, defaults: UserDefaults = .standard, deletePairing: @escaping () throws -> Void = PairingStore.delete, delay: @escaping () async throws -> Void = { try await Task.sleep(for: .milliseconds(2500)) }, render: @escaping (UIImage, PKDrawing, CGRect?) throws -> Data = ImageRenderer.png, saveCapture: @escaping (CaptureHistory, CaptureEntry) throws -> HistoryEntry = { try $0.save($1) }, historyDirectory: URL? = nil, takeInboxImage: @escaping () -> UIImage? = { SharedInbox().takeNewest() }) {
        let directory = historyDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Captures", isDirectory: true)
        storage = CaptureHistory(directory: directory)
        self.client = client
        self.pairing = pairing
        self.defaults = defaults
        appearance = Appearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        retention = Retention(rawValue: defaults.string(forKey: "captureRetention") ?? "") ?? .forever
        self.deletePairing = deletePairing
        self.delay = delay
        self.render = render
        self.saveCapture = saveCapture
        self.takeInboxImage = takeInboxImage
        let savedWidth = CGFloat(defaults.double(forKey: "lineWidth"))
        lineWidth = Self.lineWidths.contains(savedWidth) ? savedWidth : Self.lineWidths[1]
        do { history = try storage.load() } catch { self.error = error.localizedDescription }
        pruneHistory()
        migrateThumbnails()
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
        if let image = takeInboxImage() {
            await importImage(image)
            return
        }
        guard !importing, !imported, drawing.strokes.isEmpty, crop == nil, !busy else { return }
        await refresh()
    }

    func importImage(_ image: UIImage) async {
        importing = true
        revision += 1
        defer { importing = false }
        guard await flushHistory() else { return }
        if let current = currentEntry() {
            queueSave(current)
            guard await flushHistory() else { return }
        }
        debounce?.cancel()
        resetting = true
        self.image = image
        imported = true
        windows = []
        drawing = PKDrawing()
        crop = nil
        resetting = false
        session = UUID().uuidString
        captureDate = Date()
        cropUndo = []
        delivered = false
        sendError = nil
        queueSave(currentEntry()!)
        _ = await flushHistory()
        hasPendingSend = true
        readyRevision = revision
        await sendIfReady()
    }

    func sendImportedAfterPairing() async {
        await sendIfReady()
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
        let captureRevision = revision
        defer { busy = false }
        do {
            guard await flushHistory() else { return }
            if selectedDisplay != nil {
                displays = try await client.displays()
                if !displays.contains(where: { $0.id == selectedDisplay }) {
                    selectedDisplay = nil
                }
            }
            let capture = try await client.capture(displayId: selectedDisplay)
            guard revision == captureRevision else { return }
            guard let image = UIImage(data: capture.png) else { throw MacError.unexpected }
            if let current = currentEntry() {
                queueSave(current)
                guard await flushHistory() else { return }
            }
            guard revision == captureRevision else { return }
            resetting = true
            self.image = image
            imported = false
            windows = capture.windows
            drawing = PKDrawing()
            crop = nil
            resetting = false
            session = UUID().uuidString
            captureDate = Date()
            cropUndo = []
            queueSave(currentEntry()!)
            _ = await flushHistory()
            revision += 1
            debounce?.cancel()
            readyRevision = nil
            hasPendingSend = false
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
        return CaptureEntry(id: session, date: captureDate, image: image, drawing: drawing, crop: crop, windows: windows, imported: imported)
    }

    private func queueSave(_ entry: CaptureEntry) {
        pendingSave = entry
        guard saveTask == nil else { return }
        historySaveFailed = false
        saveTask = Task {
            while let entry = pendingSave {
                pendingSave = nil
                let storage = storage
                let saveCapture = saveCapture
                do {
                    let item = try await Task.detached(priority: .utility) { try saveCapture(storage, entry) }.value
                    history.removeAll { $0.id == entry.id }
                    history.append(item)
                    history.sort { $0.date > $1.date }
                } catch {
                    historySaveFailed = true
                    self.error = error.localizedDescription
                    pendingSave = pendingSave ?? entry
                    break
                }
            }
            saveTask = nil
        }
    }

    @discardableResult func flushHistory() async -> Bool {
        if historySaveFailed, let entry = pendingSave {
            queueSave(entry)
        }
        while let task = saveTask {
            await task.value
        }
        return !historySaveFailed
    }

    private func migrateThumbnails() {
        let missing = history.filter { $0.thumbnail == nil }
        let storage = storage
        Task {
            for entry in missing {
                let data = await Task.detached(priority: .utility) { () -> Data? in
                    do {
                        let capture = try storage.loadCapture(entry)
                        return try ImageRenderer.thumbnail(image: capture.image, drawing: capture.drawing, crop: capture.crop)
                    } catch { return nil }
                }.value
                guard let data, let index = history.firstIndex(where: { $0.id == entry.id && $0.thumbnail == nil }) else { continue }
                do {
                    try storage.saveThumbnail(data, id: entry.id)
                    history[index].thumbnail = UIImage(data: data)
                } catch { self.error = error.localizedDescription }
            }
        }
    }

    func select(_ entry: HistoryEntry) async {
        do {
            guard await flushHistory() else { return }
            let capture = try storage.loadCapture(entry)
            if let current = currentEntry() {
                queueSave(current)
                guard await flushHistory() else { return }
            }
            debounce?.cancel()
            revision += 1
            readyRevision = nil
            hasPendingSend = false
            resetting = true
            image = capture.image
            imported = capture.imported
            windows = capture.windows
            drawing = capture.drawing
            crop = capture.crop
            session = capture.id
            captureDate = capture.date
            cropUndo = []
            resetting = false
            delivered = false
            hasPendingSend = true
            readyRevision = revision
            await sendIfReady()
        } catch { self.error = error.localizedDescription }
    }

    func deleteHistory(_ entry: HistoryEntry) async {
        guard await flushHistory() else { return }
        do {
            try storage.delete(entry.id)
            history.removeAll { $0.id == entry.id }
            if entry.id == session {
                clearEditor()
            }
        } catch { self.error = error.localizedDescription }
    }

    func updateStorageSize() {
        do { storageSize = try storage.size() } catch { self.error = error.localizedDescription }
    }

    func deleteAllHistory() async {
        guard await flushHistory() else { return }
        do {
            try storage.deleteAll()
            history.removeAll()
            clearEditor()
            updateStorageSize()
        } catch { self.error = error.localizedDescription }
    }

    func pruneHistoryAfterSave() async {
        guard await flushHistory() else { return }
        pruneHistory()
        updateStorageSize()
    }

    private func pruneHistory(now: Date = Date()) {
        guard let interval = retention.interval else { return }
        for entry in history where entry.date < now.addingTimeInterval(-interval) && (image == nil || entry.id != session) {
            do {
                try storage.delete(entry.id)
                history.removeAll { $0.id == entry.id }
            } catch { self.error = error.localizedDescription }
        }
    }

    private func clearEditor() {
        debounce?.cancel()
        revision += 1
        readyRevision = nil
        hasPendingSend = false
        resetting = true
        image = nil
        imported = false
        windows = []
        drawing = PKDrawing()
        crop = nil
        resetting = false
        cropUndo = []
        delivered = false
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
            queueSave(current)
        }
        revision += 1
        hasPendingSend = true
        delivered = false
        sendError = nil
        readyRevision = nil
        scheduleSend()
    }

    func setUsingTool(_ active: Bool) {
        usingTool = active
        if active {
            debounce?.cancel()
            readyRevision = nil
        } else if hasPendingSend, image != nil {
            scheduleSend()
        }
    }

    private func scheduleSend() {
        debounce?.cancel()
        guard !usingTool else { return }
        let next = revision
        debounce = Task {
            do { try await delay() } catch { return }
            guard !Task.isCancelled, !usingTool, revision == next else { return }
            readyRevision = next
            Task { await sendIfReady() }
        }
    }

    private func sendIfReady() async {
        guard !sending, !usingTool, let current = readyRevision, let image, let client else { return }
        readyRevision = nil
        hasPendingSend = false
        let currentSession = session
        let drawing = drawing
        let crop = crop
        let render = render
        sending = true
        do {
            let data = try await Task.detached(priority: .utility) {
                try render(image, drawing, crop)
            }.value
            try await client.paste(data, session: currentSession)
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
