import CompanionKit
import CoreGraphics
import Foundation
import PencilKit

struct ReplayStroke: Equatable {
    let start: Double
    let offsets: [Double]

    init(start: Double, offsets: [Double]) {
        self.start = start
        self.offsets = offsets
    }

    init(_ stroke: PKStroke, sessionStart: Date) {
        start = stroke.path.creationDate.timeIntervalSince(sessionStart)
        offsets = Array(stroke.path).map(\.timeOffset)
    }

    var end: Double {
        start + (offsets.last ?? 0)
    }
}

struct StrokeProgress: Equatable {
    var points: Int
    var tail: Double
}

struct ReplayTimeline {
    static let gapLimit = 3.0
    static let gapLength = 1.0

    private struct Piece {
        let sessionFrom: Double
        let sessionTo: Double
        let replayFrom: Double
        let replayTo: Double
    }

    let strokes: [ReplayStroke]
    let recordings: [VoiceRecording]
    let phrases: [NotePhrase]
    let marks: [NoteMark]
    let duration: Double
    private let pieces: [Piece]

    init(strokes: [ReplayStroke], recordings: [VoiceRecording], phrases: [NotePhrase], marks: [NoteMark]) {
        self.strokes = strokes
        self.recordings = recordings
        self.phrases = phrases
        self.marks = marks
        var spans = strokes.map { ($0.start, $0.end) }
        spans += recordings.map { ($0.start, $0.start + $0.duration) }
        spans += phrases.map { ($0.start, max($0.start, $0.end)) }
        spans += marks.map { ($0.start, $0.start) }
        var cursor = min(0, spans.map(\.0).min() ?? 0)
        var replay = 0.0
        var pieces: [Piece] = []
        for (from, to) in spans.sorted(by: { $0.0 < $1.0 }) {
            if from > cursor {
                let gap = from - cursor
                let length = gap > Self.gapLimit ? Self.gapLength : gap
                pieces.append(Piece(sessionFrom: cursor, sessionTo: from, replayFrom: replay, replayTo: replay + length))
                replay += length
                cursor = from
            }
            if to > cursor {
                pieces.append(Piece(sessionFrom: cursor, sessionTo: to, replayFrom: replay, replayTo: replay + (to - cursor)))
                replay += to - cursor
                cursor = to
            }
        }
        self.pieces = pieces
        duration = replay
    }

    init(drawing: PKDrawing, timeline: VoiceTimeline) {
        self.init(strokes: drawing.strokes.map { ReplayStroke($0, sessionStart: timeline.sessionStart) }, recordings: timeline.recordings, phrases: timeline.note.phrases, marks: timeline.note.marks)
    }

    func replayTime(forSession session: Double) -> Double {
        guard let first = pieces.first, let last = pieces.last else { return 0 }
        if session <= first.sessionFrom {
            return 0
        }
        if session >= last.sessionTo {
            return duration
        }
        guard let piece = pieces.last(where: { $0.sessionFrom <= session }) else { return 0 }
        return piece.replayFrom + (session - piece.sessionFrom) / (piece.sessionTo - piece.sessionFrom) * (piece.replayTo - piece.replayFrom)
    }

    func sessionTime(forReplay replay: Double) -> Double {
        guard let first = pieces.first, let last = pieces.last else { return 0 }
        if replay <= 0 {
            return first.sessionFrom
        }
        if replay >= duration {
            return last.sessionTo
        }
        guard let piece = pieces.last(where: { $0.replayFrom <= replay }), piece.replayTo > piece.replayFrom else { return last.sessionTo }
        return piece.sessionFrom + (replay - piece.replayFrom) / (piece.replayTo - piece.replayFrom) * (piece.sessionTo - piece.sessionFrom)
    }

    func progress(at replay: Double) -> [StrokeProgress] {
        let session = sessionTime(forReplay: replay) + 1e-9
        return strokes.map { stroke in
            guard stroke.start <= session else { return StrokeProgress(points: 0, tail: 0) }
            let count = stroke.offsets.filter { stroke.start + $0 <= session }.count
            guard count > 0 else { return StrokeProgress(points: 1, tail: 0) }
            guard count < stroke.offsets.count else { return StrokeProgress(points: count, tail: 0) }
            let from = stroke.start + stroke.offsets[count - 1]
            let to = stroke.start + stroke.offsets[count]
            return StrokeProgress(points: count, tail: to > from ? min(1, max(0, (session - from) / (to - from))) : 0)
        }
    }

    func visiblePoints(at replay: Double) -> [Int] {
        progress(at: replay).map(\.points)
    }

    func phraseIndex(at replay: Double) -> Int? {
        let session = sessionTime(forReplay: replay) + 1e-9
        return phrases.lastIndex { $0.start <= session }
    }

    func visibleMarks(at replay: Double) -> [NoteMark] {
        let session = sessionTime(forReplay: replay) + 1e-9
        return marks.filter { $0.start <= session }
    }

    func recordingStart(_ recording: VoiceRecording) -> Double {
        replayTime(forSession: recording.start)
    }

    static func clock(_ seconds: Double) -> String {
        let whole = Int(max(0, seconds))
        return "\(whole / 60):" + String(format: "%02d", whole % 60)
    }

    static func chipOrigin(mark: NoteMark, in rect: CGRect, chip: CGFloat) -> CGPoint {
        let left = CGFloat(mark.x) - chip
        let top = CGFloat(mark.y) - chip
        let x = max(rect.minX, min(left < rect.minX ? CGFloat(mark.x) : left, rect.maxX - chip))
        let y = max(rect.minY, min(top < rect.minY ? CGFloat(mark.y) : top, rect.maxY - chip))
        return CGPoint(x: x, y: y)
    }
}
