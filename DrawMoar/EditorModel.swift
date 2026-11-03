import CompanionKit
import Observation
import os
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

enum DrawTool: String, CaseIterable {
    case pen, marker, eraser
}

enum InkColor: String, CaseIterable {
    case red, orange, yellow, green, blue, black

    var color: UIColor {
        switch self {
        case .red: UIColor(red: 1, green: 0.231, blue: 0.188, alpha: 1)
        case .orange: UIColor(red: 1, green: 0.584, blue: 0, alpha: 1)
        case .yellow: UIColor(red: 1, green: 0.8, blue: 0, alpha: 1)
        case .green: UIColor(red: 0.204, green: 0.78, blue: 0.349, alpha: 1)
        case .blue: UIColor(red: 0, green: 0.478, blue: 1, alpha: 1)
        case .black: .black
        }
    }
}

private struct VoiceSession {
    let started: Date
    var marks: [NoteMark]
    var phrases: [NotePhrase]
    var recordings: [VoiceRecording] = []
}

@MainActor private final class Deadline<T> {
    var continuation: CheckedContinuation<T, Error>?
    var work: Task<Void, Never>?
    var timer: Task<Void, Never>?

    func finish(_ result: Result<T, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        work?.cancel()
        timer?.cancel()
        continuation.resume(with: result)
    }
}

enum EditorMode: String {
    case draw, note
}

@MainActor @Observable final class EditorModel {
    let voice: VoiceModel
    private let deadline: Duration
    private var voiceSession: VoiceSession?
    private let recorder = VoiceRecorder()
    private let startVoice: (() async throws -> Void)?
    private let stopVoice: (() -> (samples: [Float], started: Date))?
    private let transcribeVoice: (([Float]) async throws -> [NoteBuilder.Word])?
    var recording = false
    private(set) var startingRecording = false
    var transcribing = false
    var showVoiceSettings = false
    var mode: EditorMode {
        didSet {
            guard mode != oldValue else { return }
            defaults.set(mode.rawValue, forKey: "editorMode")
            debounce?.cancel()
            readyRevision = nil
            if mode == .draw, hasPendingSend {
                scheduleSend()
            }
        }
    }

    var image: UIImage?
    private(set) var windows: [WindowFrame] = []
    private var session = UUID().uuidString
    private var captureDate = Date()
    private(set) var imported = false
    private(set) var history: [HistoryEntry] = []
    private let storage: CaptureHistory
    private let capturesDirectory: URL
    private(set) var storageSize: Int64 = 0
    var retention: Retention {
        didSet { defaults.set(retention.rawValue, forKey: "captureRetention") }
    }

    private enum Action {
        case drawing(before: PKDrawing, after: PKDrawing)
        case crop(before: CGRect?, after: CGRect?)
    }

    private var undoStack: [Action] = []
    private var redoStack: [Action] = []
    private var applyingHistory = false
    var canUndo: Bool {
        !undoStack.isEmpty
    }

    var canRedo: Bool {
        !redoStack.isEmpty
    }

    private var windowChain: [WindowFrame] = []
    private var windowDepth = 0
    var drawing = PKDrawing() {
        didSet {
            if drawing != oldValue {
                record(.drawing(before: oldValue, after: drawing))
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
    private(set) var tool: DrawTool
    private(set) var inkColor: InkColor
    static let lineWidths: [CGFloat] = [4, 8, 16, 32]
    var client: (any MacCapturing)?
    var pairing: Pairing?
    private let defaults: UserDefaults
    private let deletePairing: () throws -> Void
    private let delay: () async throws -> Void
    private let render: (UIImage, PKDrawing, CGRect?) throws -> Data
    private let takeInboxImage: () -> UIImage?
    private let saveCapture: (CaptureHistory, CaptureEntry) throws -> HistoryEntry
    private var sendWaiters: [CheckedContinuation<Void, Never>] = []
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

    init(client: (any MacCapturing)?, pairing: Pairing? = nil, defaults: UserDefaults = .standard, deletePairing: @escaping () throws -> Void = PairingStore.delete, delay: @escaping () async throws -> Void = { try await Task.sleep(for: .milliseconds(2500)) }, render: @escaping (UIImage, PKDrawing, CGRect?) throws -> Data = ImageRenderer.png, saveCapture: @escaping (CaptureHistory, CaptureEntry) throws -> HistoryEntry = { try $0.save($1) }, historyDirectory: URL? = nil, takeInboxImage: @escaping () -> UIImage? = { SharedInbox().takeNewest() }, startVoice: (() async throws -> Void)? = nil, stopVoice: (() -> (samples: [Float], started: Date))? = nil, transcribeVoice: (([Float]) async throws -> [NoteBuilder.Word])? = nil, voice: VoiceModel? = nil, deadline: Duration = .seconds(180)) {
        self.voice = voice ?? VoiceModel()
        self.deadline = deadline
        let directory = historyDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Captures", isDirectory: true)
        storage = CaptureHistory(directory: directory)
        capturesDirectory = directory
        self.client = client
        self.pairing = pairing
        self.defaults = defaults
        mode = EditorMode(rawValue: defaults.string(forKey: "editorMode") ?? "") ?? .draw
        appearance = Appearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        retention = Retention(rawValue: defaults.string(forKey: "captureRetention") ?? "") ?? .forever
        self.deletePairing = deletePairing
        self.delay = delay
        self.render = render
        self.saveCapture = saveCapture
        self.takeInboxImage = takeInboxImage
        self.startVoice = startVoice
        self.stopVoice = stopVoice
        self.transcribeVoice = transcribeVoice
        tool = DrawTool(rawValue: defaults.string(forKey: "drawTool") ?? "") ?? .pen
        inkColor = InkColor(rawValue: defaults.string(forKey: "inkColor") ?? "") ?? .red
        let savedWidth = CGFloat(defaults.double(forKey: "lineWidth"))
        lineWidth = Self.lineWidths.contains(savedWidth) ? savedWidth : Self.lineWidths[1]
        do { history = try storage.load() } catch { self.error = error.localizedDescription }
        pruneHistory()
        migrateThumbnails()
        if let value = defaults.object(forKey: "displayId") as? Int {
            selectedDisplay = UInt32(exactly: value)
        }
    }

    func toggleRecording() async {
        if !recording {
            guard !startingRecording else { return }
            guard voice.installed || startVoice != nil else { showVoiceSettings = true; return }
            startingRecording = true
            defer { startingRecording = false }
            do {
                if let startVoice {
                    try await startVoice()
                } else {
                    try await recorder.start()
                }
                recording = true; error = nil
            } catch { self.error = error.localizedDescription }
            return
        }
        let result = stopVoice?() ?? (samples: recorder.stop(), started: recorder.started)
        let samples = result.samples
        let started = result.started
        let duration = Date().timeIntervalSince(started)
        recording = false
        let level = VoiceSignal.rms(samples)
        voiceLog.info("recording \(Double(samples.count) / 16000, format: .fixed(precision: 1), privacy: .public) s rms \(level, format: .exponential(precision: 2), privacy: .public)")
        if !samples.isEmpty, level < VoiceSignal.silenceThreshold {
            error = VoiceSignal.silentMessage
            return
        }
        transcribing = true
        defer { transcribing = false }
        do {
            let voice = voice
            let transcribeVoice = transcribeVoice
            let words = try await withDeadline {
                if let transcribeVoice {
                    return try await transcribeVoice(samples)
                }
                return try await voice.transcribe(samples)
            }
            try await sendVoiceNote(words: words, started: started, duration: duration, samples: samples)
        } catch { self.error = error.localizedDescription }
    }

    private func withDeadline<T>(_ operation: @escaping () async throws -> T) async throws -> T {
        let limit = deadline
        let state = Deadline<T>()
        return try await withCheckedThrowingContinuation { continuation in
            state.continuation = continuation
            state.work = Task {
                do {
                    let value = try await operation()
                    state.finish(.success(value))
                } catch { state.finish(.failure(error)) }
            }
            state.timer = Task {
                do { try await Task.sleep(for: limit) } catch { return }
                state.finish(.failure(VoiceError.timedOut))
            }
        }
    }

    func sendVoiceNote(words: [NoteBuilder.Word], started: Date, duration: Double, samples: [Float] = []) async throws {
        let currentSession = session
        let size = image?.cgImage.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
        let scale = size == .zero ? 1 : Self.canvasScale(for: size)
        let strokes = image == nil ? [] : drawing.strokes.map {
            NoteBuilder.Stroke(start: $0.path.creationDate.timeIntervalSince(started), bounds: $0.renderBounds.applying(CGAffineTransform(scaleX: 1 / scale, y: 1 / scale)))
        }
        let previous = voiceSession ?? VoiceSession(started: started, marks: [], phrases: [])
        let offset = started.timeIntervalSince(previous.started)
        let segment = NoteBuilder.build(words: words, strokes: strokes, windows: windows, size: size, display: displays.first(where: { $0.id == selectedDisplay })?.name, duration: duration, firstMark: previous.marks.count + 1)
        let marks = previous.marks + segment.marks.map { NoteMark(number: $0.number, start: $0.start + offset, x: $0.x, y: $0.y, width: $0.width, height: $0.height, on: $0.on) }
        let phrases = previous.phrases + segment.phrases.map { NotePhrase(start: $0.start + offset, end: $0.end + offset, text: $0.text, marks: $0.marks) }
        let note = Note(displayName: segment.displayName, width: segment.width, height: segment.height, duration: offset + duration, marks: marks, phrases: phrases)
        var recordings = previous.recordings
        if !samples.isEmpty, image != nil {
            let id = currentSession
            let storage = storage
            let number = recordings.count + 1
            do {
                let file = try await Task.detached(priority: .utility) { try storage.saveVoice(samples, id: id, number: number) }.value
                recordings.append(VoiceRecording(file: file, start: offset, duration: Double(samples.count) / 16000))
                let timeline = VoiceTimeline(sessionStart: previous.started, recordings: recordings, note: note)
                try await Task.detached(priority: .utility) { try storage.saveTimeline(timeline, id: id) }.value
                if let index = history.firstIndex(where: { $0.id == id }) {
                    history[index].hasTimeline = true
                }
            } catch { self.error = error.localizedDescription }
        }
        if session == currentSession {
            voiceSession = VoiceSession(started: previous.started, marks: marks, phrases: phrases, recordings: recordings)
        }
        let annotated = try image.map { try ImageRenderer.noteImage(image: $0, drawing: drawing, crop: crop, marks: note.marks) } ?? Data()
        let screenshot = Data()
        guard let client else { throw MacError.unavailable([]) }
        let sentRevision = revision
        if sending {
            await withCheckedContinuation { sendWaiters.append($0) }
        } else {
            sending = true
        }
        defer {
            sending = false
            if !resumeSendWaiter() {
                Task { await sendIfReady() }
            }
        }
        do { try await client.note(annotated: annotated, screenshot: screenshot, note: note, session: currentSession) }
        catch let failure as MacError {
            if case .unavailable = failure {
                throw failure
            }
            try await client.paste(annotated, session: currentSession)
            error = "Update ClipMoar for voice notes"
        } catch {
            try await client.paste(annotated, session: currentSession)
            self.error = "Update ClipMoar for voice notes"
        }
        if revision == sentRevision, session == currentSession {
            hasPendingSend = false
            delivered = true
        }
    }

    func setLineWidth(_ width: CGFloat) {
        guard Self.lineWidths.contains(width) else { return }
        lineWidth = width
        defaults.set(Double(width), forKey: "lineWidth")
    }

    func setTool(_ tool: DrawTool) {
        self.tool = tool
        defaults.set(tool.rawValue, forKey: "drawTool")
    }

    func setInkColor(_ color: InkColor) {
        inkColor = color
        defaults.set(color.rawValue, forKey: "inkColor")
    }

    nonisolated static func canvasScale(for size: CGSize) -> CGFloat {
        min(1, 2048 / max(size.width, size.height))
    }

    static func pkTool(_ tool: DrawTool, color: InkColor, width: CGFloat, scale: CGFloat) -> PKTool {
        let type: PKInkingTool.InkType
        switch tool {
        case .eraser: return PKEraserTool(.vector)
        case .pen: type = .pen
        case .marker: type = .marker
        }
        let range = type.validWidthRange
        return PKInkingTool(type, color: color.color, width: min(max(width * scale, range.lowerBound), range.upperBound))
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
        replaceSession(UUID().uuidString)
        captureDate = Date()
        clearHistory()
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
            replaceSession(UUID().uuidString)
            captureDate = Date()
            clearHistory()
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

    private func replaceSession(_ id: String) {
        session = id
        voiceSession = nil
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
            replaceSession(capture.id)
            if let timeline = capture.timeline {
                voiceSession = VoiceSession(started: timeline.sessionStart, marks: timeline.note.marks, phrases: timeline.note.phrases, recordings: timeline.recordings)
            }
            captureDate = capture.date
            clearHistory()
            resetting = false
            delivered = false
            hasPendingSend = true
            readyRevision = revision
            await sendIfReady()
        } catch { self.error = error.localizedDescription }
    }

    var sessionPhrases: [NotePhrase] {
        voiceSession?.phrases ?? []
    }

    var replayAvailable: Bool {
        history.first { $0.id == session }?.hasTimeline == true
    }

    func replaySource(for entry: HistoryEntry) async -> ReplaySource? {
        let storage = storage
        let directory = capturesDirectory
        do {
            let capture = try await Task.detached(priority: .userInitiated) { try storage.loadCapture(entry) }.value
            guard let timeline = capture.timeline else { return nil }
            return ReplaySource(id: capture.id, image: capture.image, drawing: capture.drawing, crop: capture.crop, timeline: timeline, directory: directory)
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    func replaySourceForCurrent() async -> ReplaySource? {
        if let current = currentEntry() {
            queueSave(current)
        }
        guard await flushHistory(), let entry = history.first(where: { $0.id == session && $0.hasTimeline }) else { return nil }
        return await replaySource(for: entry)
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
        clearHistory()
        delivered = false
    }

    func applyCrop(_ rect: CGRect) {
        guard crop != rect else { return }
        record(.crop(before: crop, after: rect))
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

    func undo() {
        guard let action = undoStack.popLast() else { return }
        apply(action, forward: false)
        redoStack.append(action)
    }

    func redo() {
        guard let action = redoStack.popLast() else { return }
        apply(action, forward: true)
        undoStack.append(action)
    }

    private func apply(_ action: Action, forward: Bool) {
        applyingHistory = true
        defer { applyingHistory = false }
        switch action {
        case let .drawing(before, after): drawing = forward ? after : before
        case let .crop(before, after): crop = forward ? after : before
        }
    }

    private func record(_ action: Action) {
        guard !resetting, !applyingHistory else { return }
        undoStack.append(action)
        redoStack = []
    }

    private func clearHistory() {
        undoStack = []
        redoStack = []
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

    nonisolated static func interruptsPenStroke(scenePhase: ScenePhase, modalPresented: Bool) -> Bool {
        scenePhase != .active || modalPresented
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
        guard mode == .draw, !usingTool else { return }
        let next = revision
        debounce = Task {
            do { try await delay() } catch { return }
            guard !Task.isCancelled, mode == .draw, !usingTool, revision == next else { return }
            readyRevision = next
            Task { await sendIfReady() }
        }
    }

    private func resumeSendWaiter() -> Bool {
        guard !sendWaiters.isEmpty else { return false }
        sending = true
        sendWaiters.removeFirst().resume()
        return true
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
        if !resumeSendWaiter(), readyRevision != nil {
            await sendIfReady()
        }
    }
}
