import CompanionKit
@testable import DrawMoar
import PencilKit
import XCTest

final class ReplayTests: XCTestCase {
    private func timeline(strokes: [ReplayStroke] = [], phrases: [NotePhrase] = [], marks: [NoteMark] = []) -> ReplayTimeline {
        ReplayTimeline(strokes: strokes, recordings: [VoiceRecording(file: "a.m4a", start: 0, duration: 5), VoiceRecording(file: "b.m4a", start: 60, duration: 5)], phrases: phrases, marks: marks)
    }

    func testLongGapIsCompressed() {
        let replay = timeline()
        XCTAssertEqual(replay.duration, 11, accuracy: 1e-9)
        XCTAssertEqual(replay.replayTime(forSession: 60), 6, accuracy: 1e-9)
        XCTAssertEqual(replay.sessionTime(forReplay: 6.6), 60.6, accuracy: 1e-9)
        XCTAssertEqual(replay.sessionTime(forReplay: replay.replayTime(forSession: 3)), 3, accuracy: 1e-9)
    }

    func testStrokeRevealsPointsByOffset() {
        let replay = ReplayTimeline(strokes: [ReplayStroke(start: 2, offsets: [0, 0.5, 1.0])], recordings: [], phrases: [], marks: [])
        XCTAssertEqual(replay.visiblePoints(at: 1.9), [0])
        XCTAssertEqual(replay.visiblePoints(at: 2.6), [2])
        XCTAssertEqual(replay.visiblePoints(at: 3.5), [3])
        let point = PKStrokePoint(location: .zero, timeOffset: 0.5, size: CGSize(width: 1, height: 1), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        let start = Date(timeIntervalSince1970: 100)
        let stroke = PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: [point, point], creationDate: start.addingTimeInterval(2)))
        XCTAssertEqual(ReplayStroke(stroke, sessionStart: start), ReplayStroke(start: 2, offsets: [0.5, 0.5]))
    }

    func testPhraseAndMarkFollowReplayClock() {
        let phrases = [NotePhrase(start: 0.5, end: 1, text: "one", marks: []), NotePhrase(start: 60.5, end: 61, text: "two", marks: [1])]
        let marks = [NoteMark(number: 1, start: 61, x: 0, y: 0, width: 1, height: 1, on: nil)]
        let replay = timeline(phrases: phrases, marks: marks)
        XCTAssertEqual(replay.phraseIndex(at: 6.6), 1)
        XCTAssertEqual(replay.phraseIndex(at: 0.2), nil)
        XCTAssertEqual(replay.visibleMarks(at: 6.9).count, 0)
        XCTAssertEqual(replay.visibleMarks(at: 7.1).map(\.number), [1])
        XCTAssertEqual(ReplayTimeline.clock(125.9), "2:05")
    }
}
