import AVFoundation
import CompanionKit
@testable import DrawMoar
import FluidAudio
import PencilKit
import XCTest

final class VoiceTests: XCTestCase {
    func testDownloadText() {
        let text = DownloadText(fraction: 0.42, phase: .downloading(completedFiles: 2, totalFiles: 7), downloaded: 265_000_000, total: 630_000_000)
        XCTAssertEqual(text.percent, "42%")
        XCTAssertEqual(text.phase, "File 3 of 7")
        XCTAssertEqual(text.bytes, "265 MB of 630 MB")
        XCTAssertFalse(DownloadText(fraction: 0, phase: .listing, downloaded: 0, total: nil).bytes.contains(" of "))
    }

    @MainActor func testDrawingModesAndPersistence() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let client = VoiceClient()
        let model = EditorModel(client: client, defaults: defaults, delay: {}, startVoice: {}, stopVoice: { ([], Date().addingTimeInterval(-1)) }, transcribeVoice: { _ in [] })
        model.image = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { _ in }
        let point = PKStrokePoint(location: CGPoint(x: 1, y: 1), timeOffset: 0, size: CGSize(width: 1, height: 1), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        let stroke = PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: [point, point], creationDate: Date()))
        let pasted = expectation(description: "drawing sent")
        client.onPaste = { pasted.fulfill() }
        model.drawing = PKDrawing(strokes: [stroke])
        await fulfillment(of: [pasted], timeout: 5)
        XCTAssertNotNil(try UIImage(data: XCTUnwrap(client.pasted)))
        XCTAssertEqual(client.noteCount, 0)
        client.onPaste = nil
        client.pasted = nil
        model.mode = .note
        XCTAssertEqual(EditorModel(client: nil, defaults: defaults).mode, .note)
        await model.toggleRecording()
        model.drawing = PKDrawing(strokes: [stroke, stroke])
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        XCTAssertNil(client.pasted)
        await model.toggleRecording()
        XCTAssertEqual(client.noteCount, 1)
        XCTAssertNil(client.pasted)
    }

    func testGroupsAndPhrases() {
        let rect = CGRect(x: 10, y: 10, width: 20, height: 20)
        let words = [NoteBuilder.Word(text: "first", start: 1, end: 1.2), .init(text: "second", start: 4, end: 4.2)]
        let note = NoteBuilder.build(words: words, strokes: [.init(start: 0.5, bounds: rect), .init(start: 3.5, bounds: rect)], windows: [], size: .zero, display: nil, duration: 5)
        XCTAssertEqual(note.marks.count, 2)
        XCTAssertEqual(note.phrases.last?.marks, [2])
        let overlap = NoteBuilder.build(words: [], strokes: [.init(start: 0, bounds: rect), .init(start: 0.8, bounds: rect)], windows: [], size: .zero, display: nil, duration: 1)
        XCTAssertEqual(overlap.marks.count, 1)
        let separate = NoteBuilder.build(words: [], strokes: [.init(start: 0, bounds: rect), .init(start: 0.8, bounds: rect.offsetBy(dx: 100, dy: 0)), .init(start: -1, bounds: rect)], windows: [], size: .zero, display: nil, duration: 1)
        XCTAssertEqual(separate.marks.count, 2)
    }

    func testLocationAndTokenWords() {
        let child = WindowFrame(x: 0, y: 0, width: 50, height: 50, app: "Safari", title: "web area")
        let window = WindowFrame(x: 0, y: 0, width: 100, height: 100, app: "Safari", title: "PR", children: [child])
        let note = NoteBuilder.build(words: [], strokes: [.init(start: 0, bounds: CGRect(x: 10, y: 10, width: 10, height: 10))], windows: [window], size: .zero, display: nil, duration: 1)
        XCTAssertEqual(note.marks.first?.on, "Safari › \"PR\" › web area")
        let tokens = [TokenTiming(token: "▁Hel", tokenId: 1, startTime: 1, endTime: 2, confidence: 1), TokenTiming(token: "lo", tokenId: 2, startTime: 2, endTime: 3, confidence: 1), TokenTiming(token: "▁world", tokenId: 3, startTime: 3, endTime: 4, confidence: 1)]
        let words = buildWordTimings(from: tokens)
        XCTAssertEqual(words.map(\.word), ["Hello", "world"])
        XCTAssertEqual(words[0].startTime, 1)
        XCTAssertEqual(words[0].endTime, 3)
    }

    @MainActor func testDictationAndOldMac() async throws {
        let client = VoiceClient()
        let model = try EditorModel(client: client, defaults: XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)))
        try await model.sendVoiceNote(words: [.init(text: "hello", start: 0, end: 1)], started: Date(), duration: 1)
        XCTAssertEqual(client.annotated, Data())
        XCTAssertEqual(client.screenshot, Data())
        XCTAssertEqual(client.note?.marks, [])
        client.fail = true
        model.image = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { _ in }
        try await model.sendVoiceNote(words: [], started: Date(), duration: 1)
        XCTAssertEqual(client.pasted, client.annotated)
        XCTAssertEqual(model.error, "Update ClipMoar for voice notes")
    }
}

extension VoiceTests {
    @MainActor private func makeModel(_ client: VoiceClient, deadline: Duration = .seconds(180), transcribe: @escaping ([Float]) async throws -> [NoteBuilder.Word] = { _ in [] }) throws -> EditorModel {
        let model = try EditorModel(client: client, defaults: XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)), delay: {}, historyDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), startVoice: {}, stopVoice: { ([], Date()) }, transcribeVoice: transcribe, deadline: deadline)
        model.mode = .note
        model.image = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { _ in }
        return model
    }

    private func stroke(at date: Date) -> PKStroke {
        let point = PKStrokePoint(location: CGPoint(x: 1, y: 1), timeOffset: 0, size: CGSize(width: 1, height: 1), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: [point, point], creationDate: date))
    }

    private func pngSize(_ data: Data) throws -> CGSize {
        let image = try XCTUnwrap(UIImage(data: data))
        return CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
    }

    private func bigImage() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 5120, height: 2880), format: format).image { _ in }
    }

    func testNoteRegionRules() {
        let size = CGSize(width: 5120, height: 2880)
        let marks = [NoteMark(number: 1, start: 0, x: 100, y: 100, width: 200, height: 100, on: nil), NoteMark(number: 2, start: 1, x: 1000, y: 500, width: 300, height: 200, on: nil)]
        XCTAssertEqual(ImageRenderer.noteRegion(size: size, crop: nil, marks: marks).rect, CGRect(x: 0, y: 0, width: 1480, height: 880))
        let crop = CGRect(x: 10, y: 20, width: 300, height: 200)
        XCTAssertEqual(ImageRenderer.noteRegion(size: size, crop: crop, marks: marks).rect, crop)
        let whole = ImageRenderer.noteRegion(size: size, crop: nil, marks: [])
        XCTAssertEqual(whole.rect.width * whole.scale, 1600)
    }

    @MainActor func testNoteSendsLightImageOnly() async throws {
        let client = VoiceClient()
        let model = try makeModel(client)
        model.image = bigImage()
        let started = Date(timeIntervalSince1970: 1_000_000)
        try await model.sendVoiceNote(words: [], started: started, duration: 5)
        XCTAssertTrue(client.screenshot.isEmpty)
        XCTAssertEqual(try pngSize(client.annotated).width, 1600)

        let scale = EditorModel.canvasScale(for: CGSize(width: 5120, height: 2880))
        func stroke(_ x: CGFloat, _ y: CGFloat, at date: Date) -> PKStroke {
            let points = [x, x + 300].map { PKStrokePoint(location: CGPoint(x: $0 * scale, y: y * scale), timeOffset: 0, size: CGSize(width: 1, height: 1), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2) }
            return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: date))
        }
        model.drawing = PKDrawing(strokes: [stroke(100, 100, at: started.addingTimeInterval(1)), stroke(1000, 500, at: started.addingTimeInterval(3))])
        try await model.sendVoiceNote(words: [], started: started, duration: 5)
        let note = try XCTUnwrap(client.note)
        XCTAssertEqual(note.marks.count, 2)
        let boxes = note.marks.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
        let union = boxes[0].union(boxes[1])
        let padding = max(64, max(union.width, union.height) * 0.15)
        let expected = union.insetBy(dx: -padding, dy: -padding).intersection(CGRect(x: 0, y: 0, width: 5120, height: 2880)).integral
        XCTAssertTrue(client.screenshot.isEmpty)
        XCTAssertEqual(try pngSize(client.annotated), expected.size)

        model.crop = CGRect(x: 200, y: 300, width: 640, height: 480)
        try await model.sendVoiceNote(words: [], started: started, duration: 5)
        XCTAssertEqual(try pngSize(client.annotated), CGSize(width: 640, height: 480))
    }

    @MainActor func testSessionAccumulatesUntilNew() async throws {
        let client = VoiceClient()
        let model = try makeModel(client)
        let first = Date(timeIntervalSince1970: 1_000_000)
        let strokeOne = stroke(at: first.addingTimeInterval(1))
        model.drawing = PKDrawing(strokes: [strokeOne])
        try await model.sendVoiceNote(words: [.init(text: "one", start: 0.5, end: 0.8)], started: first, duration: 5)
        let second = first.addingTimeInterval(10)
        model.drawing = PKDrawing(strokes: [strokeOne, stroke(at: second.addingTimeInterval(1))])
        try await model.sendVoiceNote(words: [.init(text: "two", start: 0.5, end: 0.8)], started: second, duration: 5)
        let note = try XCTUnwrap(client.note)
        XCTAssertEqual(note.phrases.map(\.text), ["one", "two"])
        XCTAssertEqual(note.phrases[1].start, 10.5)
        XCTAssertEqual(note.marks.map(\.number), [1, 2])
        XCTAssertEqual(note.marks.count, 2)
        XCTAssertEqual(note.duration, 15)
        XCTAssertEqual(client.sessions.count, 2)
        XCTAssertEqual(Set(client.sessions).count, 1)

        client.capturePNG = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { _ in }.pngData())
        await model.newCapture()
        XCTAssertNil(model.error)
        let third = second.addingTimeInterval(20)
        model.drawing = PKDrawing(strokes: [stroke(at: third.addingTimeInterval(1))])
        try await model.sendVoiceNote(words: [.init(text: "new", start: 0.5, end: 0.8)], started: third, duration: 5)
        let fresh = try XCTUnwrap(client.note)
        XCTAssertEqual(fresh.phrases.map(\.text), ["new"])
        XCTAssertEqual(fresh.marks.map(\.number), [1])
        XCTAssertEqual(fresh.phrases[0].start, 0.5)
        XCTAssertEqual(client.sessions.count, 3)
        XCTAssertNotEqual(client.sessions[2], client.sessions[0])
    }

    @MainActor func testTimelinePersistsRestoresAndDeletes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let base = Date(timeIntervalSince1970: 1_000_000)
        let lengths = [2, 3, 1]
        var stops = 0
        var words = 0
        let client = VoiceClient()
        client.capturePNG = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { _ in }.pngData())
        let model = try EditorModel(client: client, defaults: XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)), delay: {}, historyDirectory: directory, startVoice: {}, stopVoice: {
            defer { stops += 1 }
            return ((0 ..< lengths[stops] * 16000).map { sin(Float($0) * 0.05) * 0.3 }, base.addingTimeInterval(Double(stops) * 10))
        }, transcribeVoice: { _ in
            words += 1
            return [.init(text: ["one", "two", "three"][words - 1], start: 0.5, end: 0.8)]
        })
        model.mode = .note
        model.image = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { _ in }
        model.drawing = PKDrawing(strokes: [stroke(at: base.addingTimeInterval(1))])
        for _ in 0 ..< 2 {
            await model.toggleRecording()
            await model.toggleRecording()
        }
        XCTAssertNil(model.error)
        let id = try XCTUnwrap(client.sessions.first)
        let storage = CaptureHistory(directory: directory)
        for (number, length) in [(1, 2.0), (2, 3.0)] {
            let audio = try AVAudioFile(forReading: directory.appendingPathComponent("\(id).voice-\(number).m4a"))
            XCTAssertEqual(Double(audio.length) / audio.processingFormat.sampleRate, length, accuracy: 0.1)
        }
        let timeline = try XCTUnwrap(storage.loadTimeline(id))
        XCTAssertEqual(timeline.recordings.map(\.start), [0, 10])
        XCTAssertEqual(timeline.recordings.map(\.file), ["\(id).voice-1.m4a", "\(id).voice-2.m4a"])
        XCTAssertEqual(timeline.note.phrases.map(\.text), ["one", "two"])
        XCTAssertEqual(timeline.sessionStart, base)

        await model.newCapture()
        _ = await model.flushHistory()
        let first = try XCTUnwrap(model.history.first { $0.id == id })
        XCTAssertTrue(first.hasTimeline)
        XCTAssertEqual(model.history.filter(\.hasTimeline).count, 1)
        let other = try XCTUnwrap(model.history.first { $0.id != id })
        await model.select(other)
        await model.select(first)
        await model.toggleRecording()
        await model.toggleRecording()
        let resumed = try XCTUnwrap(client.note)
        XCTAssertEqual(resumed.phrases.map(\.text), ["one", "two", "three"])
        XCTAssertEqual(resumed.phrases[2].start, 20.5)
        XCTAssertEqual(storage.loadTimeline(id)?.recordings.count, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(id).voice-3.m4a").path))

        await model.deleteHistory(first)
        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(id) }
        XCTAssertEqual(left, [])
    }

    @MainActor func testEntryWithoutTimelineLoads() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storage = CaptureHistory(directory: directory)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { _ in }
        let saved = try storage.save(CaptureEntry(id: "old", date: Date(), image: image, drawing: PKDrawing(), crop: nil, windows: []))
        XCTAssertFalse(saved.hasTimeline)
        let entry = try XCTUnwrap(storage.load().first)
        XCTAssertFalse(entry.hasTimeline)
        XCTAssertNil(try storage.loadCapture(entry).timeline)
    }

    @MainActor func testPrepareLoadsOnce() async {
        var loads = 0
        let voice = VoiceModel(loader: {
            loads += 1
            try await Task.sleep(for: .milliseconds(50))
            return { _ in [] }
        }, installedProbe: { true })
        async let first: Void = voice.prepare()
        async let second: Void = voice.prepare()
        _ = await (first, second)
        XCTAssertEqual(loads, 1)
        XCTAssertTrue(voice.ready)
        XCTAssertFalse(voice.loading)
        await voice.prepare()
        XCTAssertEqual(loads, 1)
    }

    @MainActor func testGpuServesUntilAneSwaps() async throws {
        let ane = Gate()
        let gpu = Gate()
        weak var gpuToken: Token?
        let voice = VoiceModel(loader: {
            await ane.wait()
            return { _ in [.init(text: "ane", start: 0, end: 1)] }
        }, gpuLoader: {
            await gpu.wait()
            let token = Token()
            gpuToken = token
            return { _ in _ = token
                return [.init(text: "gpu", start: 0, end: 1)]
            }
        }, gpuGrace: .milliseconds(10), installedProbe: { true })
        let preparing = Task { await voice.prepare() }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(voice.ready)
        gpu.open()
        await preparing.value
        XCTAssertTrue(voice.ready)
        let first = try await voice.transcribe([])
        XCTAssertEqual(first.first?.text, "gpu")
        XCTAssertNotNil(gpuToken)
        ane.open()
        for _ in 0 ..< 200 {
            if try await voice.transcribe([]).first?.text == "ane" {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let second = try await voice.transcribe([])
        XCTAssertEqual(second.first?.text, "ane")
        XCTAssertNil(gpuToken)
    }

    @MainActor func testAneInsideGraceSkipsGpu() async throws {
        var gpuCalls = 0
        let voice = VoiceModel(loader: {
            try await Task.sleep(for: .milliseconds(20))
            return { _ in [.init(text: "ane", start: 0, end: 1)] }
        }, gpuLoader: {
            gpuCalls += 1
            return { _ in [] }
        }, gpuGrace: .milliseconds(300), installedProbe: { true })
        await voice.prepare()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(gpuCalls, 0)
        let words = try await voice.transcribe([])
        XCTAssertEqual(words.first?.text, "ane")
    }

    @MainActor func testTranscriptionInFlightKeepsItsTranscriber() async throws {
        let ane = Gate()
        let release = Gate()
        let voice = VoiceModel(loader: {
            await ane.wait()
            return { _ in [.init(text: "ane", start: 0, end: 1)] }
        }, gpuLoader: {
            { _ in
                await release.wait()
                return [.init(text: "gpu", start: 0, end: 1)]
            }
        }, gpuGrace: .milliseconds(10), installedProbe: { true })
        await voice.prepare()
        let inFlight = Task { try await voice.transcribe([]) }
        try await Task.sleep(for: .milliseconds(50))
        ane.open()
        try await Task.sleep(for: .milliseconds(150))
        release.open()
        let words = try await inFlight.value
        XCTAssertEqual(words.first?.text, "gpu")
        let next = try await voice.transcribe([])
        XCTAssertEqual(next.first?.text, "ane")
    }

    @MainActor func testTranscriptionDeadline() async throws {
        let model = try makeModel(VoiceClient(), deadline: .milliseconds(50)) { _ in
            try await Task.sleep(for: .seconds(1000))
            return []
        }
        await model.toggleRecording()
        XCTAssertTrue(model.recording)
        await model.toggleRecording()
        XCTAssertEqual(model.error, "Transcription timed out")
        XCTAssertFalse(model.transcribing)
        XCTAssertFalse(model.recording)
    }
}

private final class Token {}

@MainActor private final class Gate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened {
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

@MainActor private final class VoiceClient: MacCapturing {
    var capturePNG: Data?
    var sessions: [String] = []
    var annotated = Data()
    var screenshot = Data()
    var note: Note?
    var pasted: Data?
    var fail = false
    var noteCount = 0
    var onPaste: (() -> Void)?
    func capture(displayId _: UInt32?) async throws -> (png: Data, windows: [WindowFrame]) {
        guard let capturePNG else { throw MacError.unexpected }
        return (capturePNG, [])
    }

    func displays() async throws -> [DisplayInfo] {
        []
    }

    func paste(_ data: Data, session _: String) async throws {
        pasted = data
        onPaste?()
    }

    func note(annotated: Data, screenshot: Data, note: Note, session: String) async throws {
        sessions.append(session)
        self.annotated = annotated
        self.screenshot = screenshot
        self.note = note
        noteCount += 1
        if fail {
            throw MacError.remote("unknown")
        }
    }
}
