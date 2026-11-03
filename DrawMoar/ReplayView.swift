import AVFoundation
import CompanionKit
import PencilKit
import SwiftUI

struct ReplaySource: Identifiable {
    let id: String
    let image: UIImage
    let drawing: PKDrawing
    let crop: CGRect?
    let timeline: VoiceTimeline
    let directory: URL
}

@MainActor @Observable final class ReplayPlayer {
    let timeline: ReplayTimeline
    private(set) var time = 0.0
    private(set) var playing = false
    private var tracks: [(player: AVAudioPlayer, start: Double, duration: Double)] = []
    private var ticker: Task<Void, Never>?
    private var anchorUptime = 0.0
    private var anchorTime = 0.0
    private var resumeAfterScrub = false
    private let clock: () -> Double
    private let session: any AudioSessioning

    init(timeline: ReplayTimeline, directory: URL, clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }, session: any AudioSessioning = AVAudioSession.sharedInstance()) {
        self.timeline = timeline
        self.clock = clock
        self.session = session
        tracks = timeline.recordings.compactMap { recording in
            guard let player = try? AVAudioPlayer(contentsOf: directory.appendingPathComponent(recording.file)) else { return nil }
            player.prepareToPlay()
            return (player, timeline.recordingStart(recording), recording.duration)
        }
        play()
    }

    func play() {
        guard !playing else { return }
        if time >= timeline.duration {
            time = 0
        }
        try? session.configure(.playback, mode: .default)
        try? session.activate(true)
        playing = true
        anchorTime = time
        anchorUptime = clock()
        armAudio()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                self?.tick()
            }
        }
    }

    func pause() {
        playing = false
        ticker?.cancel()
        ticker = nil
        for track in tracks {
            track.player.pause()
        }
    }

    func seek(to value: Double) {
        time = min(max(0, value), timeline.duration)
        guard playing else { return }
        anchorTime = time
        anchorUptime = clock()
        armAudio()
    }

    func beginScrub() {
        resumeAfterScrub = playing
        pause()
    }

    func endScrub() {
        if resumeAfterScrub {
            resumeAfterScrub = false
            play()
        }
    }

    func stop() {
        pause()
        for track in tracks {
            track.player.stop()
        }
        tracks = []
        try? session.activate(false)
    }

    func tick() {
        guard playing else { return }
        time = min(timeline.duration, anchorTime + clock() - anchorUptime)
        if time >= timeline.duration {
            pause()
        }
    }

    private func armAudio() {
        for track in tracks {
            track.player.pause()
            if time < track.start {
                track.player.currentTime = 0
                track.player.play(atTime: track.player.deviceCurrentTime + (track.start - time))
            } else if time < track.start + track.duration {
                track.player.currentTime = time - track.start
                track.player.play()
            }
        }
    }
}

private final class InkCache {
    private let source: ReplaySource
    private let strokes: [PKStroke]
    private let scale: CGFloat
    private var key: [StrokeProgress]?
    private var renderScale: CGFloat = 0
    private var image: UIImage?

    init(source: ReplaySource) {
        self.source = source
        strokes = source.drawing.strokes
        scale = EditorModel.canvasScale(for: source.image.pixelSize)
    }

    func image(for progress: [StrokeProgress], rect: CGRect, renderScale: CGFloat) -> UIImage? {
        if key == progress, self.renderScale == renderScale {
            return image
        }
        key = progress
        self.renderScale = renderScale
        let visible = zip(strokes, progress).compactMap { partial($0, $1) }
        guard !visible.isEmpty else {
            image = nil
            return nil
        }
        let drawing = PKDrawing(strokes: visible).transformed(using: CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
        var rendered: UIImage?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            rendered = drawing.image(from: rect, scale: renderScale)
        }
        image = rendered
        return rendered
    }

    private func partial(_ stroke: PKStroke, _ progress: StrokeProgress) -> PKStroke? {
        guard progress.points > 0 else { return nil }
        let points = Array(stroke.path)
        guard progress.points < points.count else { return stroke }
        var visible = Array(points.prefix(progress.points))
        if progress.tail > 0, let last = visible.last {
            let next = points[progress.points]
            let t = CGFloat(progress.tail)
            visible.append(PKStrokePoint(location: CGPoint(x: last.location.x + (next.location.x - last.location.x) * t, y: last.location.y + (next.location.y - last.location.y) * t), timeOffset: last.timeOffset + (next.timeOffset - last.timeOffset) * progress.tail, size: last.size, opacity: last.opacity, force: last.force, azimuth: last.azimuth, altitude: last.altitude))
        }
        var result = PKStroke(ink: stroke.ink, path: PKStrokePath(controlPoints: visible, creationDate: stroke.path.creationDate))
        result.transform = stroke.transform
        return result
    }
}

private extension UIImage {
    var pixelSize: CGSize {
        cgImage.map { CGSize(width: $0.width, height: $0.height) } ?? size
    }
}

struct MarkChip: View {
    let number: Int
    var side: CGFloat = 22

    var body: some View {
        Text(String(number))
            .font(.system(size: side * 0.62, weight: .bold))
            .foregroundStyle(.black)
            .frame(width: side, height: side)
            .background(RoundedRectangle(cornerRadius: side * 0.22).fill(.white))
            .overlay(RoundedRectangle(cornerRadius: side * 0.22).stroke(Color(uiColor: .darkGray), lineWidth: 1))
            .accessibilityLabel("Mark \(number)")
    }
}

private struct ReplayStage: View {
    let player: ReplayPlayer
    let rect: CGRect
    let base: UIImage
    let ink: InkCache
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let progress = player.timeline.progress(at: player.time)
        let marks = player.timeline.visibleMarks(at: player.time)
        GeometryReader { proxy in
            let factor = proxy.size.width / rect.width
            ZStack(alignment: .topLeading) {
                Image(uiImage: base).resizable()
                if let overlay = ink.image(for: progress, rect: rect, renderScale: factor * displayScale) {
                    Image(uiImage: overlay).resizable()
                }
                ForEach(marks, id: \.number) { mark in
                    let origin = ReplayTimeline.chipOrigin(mark: mark, in: rect, chip: 22 / factor)
                    MarkChip(number: mark.number)
                        .offset(x: (origin.x - rect.minX) * factor, y: (origin.y - rect.minY) * factor)
                        .transition(.scale)
                }
            }
            .animation(.easeOut(duration: 0.15), value: marks.count)
        }
        .aspectRatio(rect.size, contentMode: .fit)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.15), lineWidth: 1))
    }
}

@MainActor private final class ReplayPlayerHolder {
    private var created: ReplayPlayer?

    func player(for source: ReplaySource) -> ReplayPlayer {
        if let created {
            return created
        }
        let player = ReplayPlayer(timeline: ReplayTimeline(drawing: source.drawing, timeline: source.timeline), directory: source.directory)
        created = player
        return player
    }
}

struct ReplayView: View {
    let source: ReplaySource
    @Environment(\.dismiss) private var dismiss
    @State private var holder = ReplayPlayerHolder()
    @State private var base: UIImage
    @State private var rect: CGRect
    @State private var ink: InkCache

    init(source: ReplaySource) {
        self.source = source
        let size = source.image.pixelSize
        let bounds = CGRect(origin: .zero, size: size)
        let region = (source.crop ?? bounds).intersection(bounds).integral
        let rect = region.isNull || region.isEmpty ? bounds : region
        _rect = State(initialValue: rect)
        _base = State(initialValue: source.image.cgImage?.cropping(to: rect).map { UIImage(cgImage: $0) } ?? source.image)
        _ink = State(initialValue: InkCache(source: source))
    }

    private var player: ReplayPlayer {
        holder.player(for: source)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                ReplayStage(player: player, rect: rect, base: base, ink: ink)
                    .frame(maxHeight: 340)
                controls
                transcript
            }
            .padding(.horizontal, 16)
            .navigationTitle("Replay")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
        .onDisappear { player.stop() }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button {
                player.playing ? player.pause() : player.play()
            } label: {
                Image(systemName: player.playing ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 40))
            }
            .accessibilityLabel(player.playing ? "Pause" : "Play")
            Slider(value: Binding(get: { player.time }, set: { player.seek(to: $0) }), in: 0 ... max(player.timeline.duration, 0.01)) { editing in
                if editing {
                    player.beginScrub()
                } else {
                    player.endScrub()
                }
            }
            .accessibilityLabel("Position")
            Text("\(ReplayTimeline.clock(player.time)) / \(ReplayTimeline.clock(player.timeline.duration))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var transcript: some View {
        let current = player.timeline.phraseIndex(at: player.time)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(Array(player.timeline.phrases.enumerated()), id: \.offset) { index, phrase in
                        row(index: index, phrase: phrase, current: current)
                            .id(index)
                    }
                }
                .padding(.bottom, 16)
            }
            .onChange(of: current) {
                guard let current else { return }
                withAnimation { proxy.scrollTo(current, anchor: .center) }
            }
        }
    }

    private func row(index: Int, phrase: NotePhrase, current: Int?) -> some View {
        TranscriptRow(phrase: phrase, active: index == current, upcoming: current.map { index > $0 } ?? true) {
            player.seek(to: player.timeline.replayTime(forSession: phrase.start) + 0.001)
        }
    }
}

struct TranscriptRow: View {
    let phrase: NotePhrase
    var active = false
    var upcoming = false
    var compact = false
    let seek: () -> Void

    static func visibleTexts(_ phrase: NotePhrase) -> [String] {
        [ReplayTimeline.clock(phrase.start), phrase.text]
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: compact ? 6 : 10) {
            Button(action: seek) {
                Text(Self.visibleTexts(phrase)[0])
                    .font((compact ? Font.caption2 : Font.caption).monospacedDigit().weight(.semibold))
                    .foregroundStyle(active ? Color.white : Color.accentColor)
                    .padding(.horizontal, compact ? 7 : 10)
                    .padding(.vertical, compact ? 2 : 4)
                    .background(Capsule().fill(active ? Color.accentColor : Color.accentColor.opacity(0.15)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Seek to \(ReplayTimeline.clock(phrase.start))")
            VStack(alignment: .leading, spacing: compact ? 2 : 6) {
                Text(Self.visibleTexts(phrase)[1])
                    .font(compact ? .caption : .body)
                    .foregroundStyle(upcoming ? Color.secondary : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(compact ? 6 : 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: compact ? 8 : 12).fill(active ? Color.accentColor.opacity(0.18) : compact ? Color.clear : Color(uiColor: .secondarySystemBackground)))
        .overlay(RoundedRectangle(cornerRadius: compact ? 8 : 12).stroke(active ? Color.accentColor : .clear, lineWidth: 1.5))
    }
}

struct TranscriptOverlay: View {
    let phrases: [NotePhrase]
    let height: CGFloat
    let openReplay: (() -> Void)?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(phrases.enumerated()), id: \.offset) { index, phrase in
                        TranscriptRow(phrase: phrase, active: false, upcoming: false, compact: true) { openReplay?() }
                            .id(index)
                    }
                }
            }
            .onAppear { proxy.scrollTo(phrases.count - 1, anchor: .bottom) }
            .onChange(of: phrases.count) { proxy.scrollTo(phrases.count - 1, anchor: .bottom) }
        }
        .frame(height: height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }
}
