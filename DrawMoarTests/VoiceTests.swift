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
