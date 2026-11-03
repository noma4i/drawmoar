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

    func testMarkChipScalesWithOutputImage() throws {
        let image = bigImage()
        func render(_ mark: NoteMark) throws -> CGImage {
            let data = try ImageRenderer.annotated(image: image, drawing: PKDrawing(), crop: CGRect(x: 0, y: 0, width: 1480, height: 880), marks: [mark])
            return try XCTUnwrap(UIImage(data: data)?.cgImage)
        }
        func rgb(_ cg: CGImage, _ x: Int, _ y: Int) -> [Int] {
            var px = [UInt8](repeating: 0, count: 4)
            let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(cg, in: CGRect(x: -x, y: y - cg.height + 1, width: cg.width, height: cg.height))
            return px.prefix(3).map(Int.init)
        }
        let far = try render(NoteMark(number: 1, start: 0, x: 200, y: 200, width: 10, height: 10, on: nil))
        XCTAssertEqual(rgb(far, 156, 174), [0, 122, 255])
        XCTAssertEqual(rgb(far, 150, 174), [255, 255, 255])
        XCTAssertEqual(rgb(far, 146, 174), [0, 0, 0])
        let edge = try render(NoteMark(number: 2, start: 0, x: 0, y: 0, width: 10, height: 10, on: nil))
        XCTAssertEqual(rgb(edge, 8, 26), [0, 122, 255])
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

    @MainActor func testEngineDefaultAndPersistence() throws {
        func suite() throws -> UserDefaults {
            try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        }
        let device = Locale.preferredLanguages
        let supported = try [AppleSpeechEngine.identifier(Locale(identifier: XCTUnwrap(device.first))), "xx-XX"]
        try XCTAssertEqual(VoiceModel(defaults: suite(), appleSupported: supported).engine, .apple)
        try XCTAssertEqual(VoiceModel(defaults: suite(), appleSupported: ["xx-XX"]).engine, .parakeet)
        let defaults = try suite()
        let model = VoiceModel(defaults: defaults, appleSupported: supported)
        model.select(.whisper)
        XCTAssertEqual(VoiceModel(defaults: defaults, appleSupported: supported).engine, .whisper)
        model.select(.parakeet)
        XCTAssertEqual(VoiceModel(defaults: defaults, appleSupported: ["xx-XX"]).engine, .parakeet)
        XCTAssertEqual(AppleSpeechEngine.language(supported: ["en-US", "ru-RU"], preferred: ["ru-RU", "en-US"]), "ru-RU")
        XCTAssertEqual(AppleSpeechEngine.language(supported: ["en-US", "ru-RU"], preferred: ["ru"]), "ru-RU")
        XCTAssertNil(AppleSpeechEngine.language(supported: ["en-US"], preferred: ["ru-RU"]))
    }

    @MainActor func testSwitchingEnginePicksOnlySelectedLoader() async throws {
        var calls: [String] = []
        let model = try VoiceModel(
            defaults: XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)),
            loader: { calls.append("parakeet"); return { _ in [.init(text: "parakeet", start: 0, end: 1)] } },
            installedProbe: { true },
            appleLoader: { _ in calls.append("apple"); return { _ in [.init(text: "apple", start: 0, end: 1)] } },
            appleSupported: ["en-US"], appleInstalled: ["en-US"],
            whisperLoader: { calls.append("whisper"); return { _ in [.init(text: "whisper", start: 0, end: 1)] } },
            whisperProbe: { true }
        )
        for engine in [VoiceEngine.whisper, .apple, .parakeet] {
            model.select(engine)
            let words = try await model.transcribe([0])
            XCTAssertEqual(words.first?.text, engine.rawValue)
            XCTAssertEqual(calls.last, engine.rawValue)
        }
        XCTAssertEqual(calls, ["whisper", "apple", "parakeet"])
    }

    func testRunsToWords() {
        let runs = [AppleSpeechEngine.Run(text: "Hello ", start: 0.5, end: 0.9), .init(text: " ", start: 0.9, end: 1.0), .init(text: "world", start: 1.0, end: 1.4)]
        let words = AppleSpeechEngine.words(from: runs)
        XCTAssertEqual(words.map(\.text), ["Hello", "world"])
        XCTAssertEqual(words.map(\.start), [0.5, 1.0])
        XCTAssertEqual(words.map(\.end), [0.9, 1.4])
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

@MainActor
extension VoiceTests {
    private func replayModel(_ client: VoiceClient) async throws -> EditorModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = try EditorModel(client: client, defaults: XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)), delay: {}, historyDirectory: directory, startVoice: {}, stopVoice: {
            ((0 ..< 16000).map { sin(Float($0) * 0.05) * 0.3 }, Date())
        }, transcribeVoice: { _ in [.init(text: "one", start: 0.1, end: 0.4)] })
        model.mode = .note
        model.image = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { _ in }
        model.drawing = PKDrawing(strokes: [stroke(at: Date())])
        _ = await model.flushHistory()
        await model.toggleRecording()
        await model.toggleRecording()
        XCTAssertNil(model.error)
        XCTAssertEqual(client.noteCount, 1)
        return model
    }

    private func waitForPaste(_ client: VoiceClient) async throws {
        for _ in 0 ..< 300 where client.pasted == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testCancelledTouchReleasesPenAndSendsPendingDraw() async throws {
        let client = VoiceClient()
        let model = try await replayModel(client)
        let source = await model.replaySourceForCurrent()
        XCTAssertNotNil(source)
        model.mode = .draw
        client.pasted = nil
        model.setUsingTool(true)
        model.drawing = PKDrawing(strokes: [stroke(at: Date())])
        var cancelled = 0
        let observer = TouchCancelObserver { cancelled += 1; model.setUsingTool(false) }
        observer.touchesCancelled([], with: UIEvent())
        XCTAssertEqual(cancelled, 1)
        try await waitForPaste(client)
        XCTAssertNotNil(client.pasted)
        XCTAssertTrue(model.delivered)
        XCTAssertFalse(model.sending)
    }

    func testSceneLeavingActiveInterruptsPenStroke() {
        XCTAssertTrue(EditorModel.interruptsPenStroke(scenePhase: .inactive, modalPresented: false))
        XCTAssertTrue(EditorModel.interruptsPenStroke(scenePhase: .background, modalPresented: false))
        XCTAssertTrue(EditorModel.interruptsPenStroke(scenePhase: .active, modalPresented: true))
        XCTAssertFalse(EditorModel.interruptsPenStroke(scenePhase: .active, modalPresented: false))
    }

    func testReplayOpenedTwiceLeavesNoSendWaiters() async throws {
        let client = VoiceClient()
        let model = try await replayModel(client)
        async let first = model.replaySourceForCurrent()
        async let second = model.replaySourceForCurrent()
        _ = await (first, second)
        XCTAssertFalse(model.sending)
        model.mode = .draw
        client.pasted = nil
        model.drawing = PKDrawing(strokes: [stroke(at: Date()), stroke(at: Date().addingTimeInterval(1))])
        try await waitForPaste(client)
        XCTAssertNotNil(client.pasted)
        XCTAssertTrue(model.delivered)
        XCTAssertFalse(model.sending)
        model.mode = .note
        await model.toggleRecording()
        await model.toggleRecording()
        XCTAssertEqual(client.noteCount, 2)
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

    func testSpeechTokenFilter() {
        func word(_ text: String, _ start: Double) -> NoteBuilder.Word {
            .init(text: text, start: start, end: start + 0.5)
        }
        XCTAssertTrue(SpeechTokens.clean([word("[BLANK_AUDIO]", 0)]).isEmpty)
        XCTAssertTrue(SpeechTokens.clean([word("[BLANK", 0), word("_AUDIO]", 1)]).isEmpty)
        XCTAssertTrue(SpeechTokens.clean([word("(silence)", 0), word("<|en|>", 1)]).isEmpty)
        let kept = SpeechTokens.clean([word("Hello", 0), word("[MUSIC]", 1), word("world", 2)])
        XCTAssertEqual(kept.map(\.text), ["Hello", "world"])
        XCTAssertEqual(kept.map(\.start), [0, 2])
        XCTAssertEqual(SpeechTokens.clean([word("<|en|>Hi", 3)]).map(\.text), ["Hi"])
    }

    func testRecorderActivatesSessionBeforeEngine() throws {
        final class Spy: AudioSessioning {
            var calls: [String] = []
            func configure(_ category: AVAudioSession.Category, mode: AVAudioSession.Mode) throws {
                calls.append("category \(category.rawValue) \(mode.rawValue)")
            }

            func activate(_ active: Bool) throws {
                calls.append("active \(active)")
            }
        }
        let spy = Spy()
        try VoiceRecorder(session: spy).activateSession()
        XCTAssertEqual(spy.calls, ["category \(AVAudioSession.Category.record.rawValue) \(AVAudioSession.Mode.default.rawValue)", "active true"])
    }

    @MainActor func testSilentTakeSendsNoNote() async throws {
        let client = VoiceClient()
        var transcribed = 0
        let model = try EditorModel(client: client, defaults: XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)), delay: {}, startVoice: {}, stopVoice: { (Array(repeating: 0, count: 32000), Date()) }, transcribeVoice: { _ in
            transcribed += 1
            return []
        })
        model.mode = .note
        model.image = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { _ in }
        await model.toggleRecording()
        await model.toggleRecording()
        XCTAssertEqual(model.error, "No audio recorded. Check the microphone.")
        XCTAssertEqual(transcribed, 0)
        XCTAssertEqual(client.noteCount, 0)
        XCTAssertFalse(model.recording)
    }
}
