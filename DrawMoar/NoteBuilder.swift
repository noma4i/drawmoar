import CompanionKit
import CoreGraphics
import Foundation

enum NoteBuilder {
    struct Word {
        let text: String
        let start: Double
        let end: Double
    }

    struct Stroke {
        let start: Double
        let bounds: CGRect
    }

    static func build(words: [Word], strokes: [Stroke], windows: [WindowFrame], size: CGSize, display: String?, duration: Double) -> Note {
        var groups: [(start: Double, last: Double, bounds: CGRect)] = []
        for stroke in strokes where stroke.start >= 0 && stroke.start <= duration {
            let padding = max(stroke.bounds.width, stroke.bounds.height) * 0.08
            if let last = groups.indices.last, stroke.start - groups[last].last < 1.5,
               stroke.bounds.insetBy(dx: -padding, dy: -padding).intersects(groups[last].bounds)
            {
                groups[last].last = stroke.start
                groups[last].bounds = groups[last].bounds.union(stroke.bounds)
            } else {
                groups.append((stroke.start, stroke.start, stroke.bounds))
            }
        }
        let marks = groups.enumerated().map { index, group in
            let box = group.bounds.integral
            return NoteMark(number: index + 1, start: group.start, x: Int(box.minX), y: Int(box.minY), width: Int(box.width), height: Int(box.height), on: location(at: CGPoint(x: box.midX, y: box.midY), windows: windows))
        }
        var phrases: [[Word]] = []
        for word in words {
            if let previous = phrases.last?.last,
               word.start - previous.end < 1,
               !marks.contains(where: { $0.start > previous.start && $0.start < word.start })
            {
                phrases[phrases.count - 1].append(word)
            } else {
                phrases.append([word])
            }
        }
        let starts = phrases.enumerated().map { index, phrase in
            let previous = index == 0 ? -Double.infinity : phrases[index - 1].last!.start
            return marks.first(where: { $0.start > previous && $0.start < phrase[0].start })?.start ?? phrase[0].start
        }
        let result = phrases.enumerated().map { index, phrase in
            let next = index + 1 < phrases.count ? starts[index + 1] : .infinity
            let start = starts[index]
            let assigned = marks.filter { $0.start >= start && $0.start < next }.map(\.number)
            return NotePhrase(start: start, end: phrase[phrase.count - 1].end, text: phrase.map(\.text).joined(separator: " "), marks: assigned)
        }
        return Note(displayName: display, width: Int(size.width), height: Int(size.height), duration: duration, marks: marks, phrases: result)
    }

    private static func location(at point: CGPoint, windows: [WindowFrame]) -> String? {
        guard let window = windows.first(where: { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height).contains(point) }) else { return nil }
        var parts = [window.app, window.title.isEmpty ? "" : "\"\(window.title)\""].filter { !$0.isEmpty }
        var children = window.children
        while let child = children.first(where: { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height).contains(point) }) {
            if !child.title.isEmpty {
                parts.append(child.title)
            }
            children = child.children
        }
        return parts.isEmpty ? nil : parts.joined(separator: " › ")
    }
}
