import CompanionKit
@testable import DrawMoar
import FluidAudio
import XCTest

final class VoiceTests: XCTestCase {
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

@MainActor private final class VoiceClient: MacCapturing {
    var annotated = Data()
    var screenshot = Data()
    var note: Note?
    var pasted: Data?
    var fail = false
    func capture(displayId _: UInt32?) async throws -> (png: Data, windows: [WindowFrame]) {
        throw MacError.unexpected
    }

    func displays() async throws -> [DisplayInfo] {
        []
    }

    func paste(_ data: Data, session _: String) async throws {
        pasted = data
    }

    func note(annotated: Data, screenshot: Data, note: Note, session _: String) async throws {
        self.annotated = annotated
        self.screenshot = screenshot
        self.note = note
        if fail {
            throw MacError.remote("unknown")
        }
    }
}
