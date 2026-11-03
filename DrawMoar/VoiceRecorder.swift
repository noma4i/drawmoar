import AVFoundation
import Foundation

protocol AudioSessioning {
    func configure(_ category: AVAudioSession.Category, mode: AVAudioSession.Mode) throws
    func activate(_ active: Bool) throws
}

extension AVAudioSession: AudioSessioning {
    func configure(_ category: Category, mode: Mode) throws {
        try setCategory(category, mode: mode, options: [])
    }

    func activate(_ active: Bool) throws {
        try setActive(active, options: [])
    }
}

final class VoiceRecorder {
    private var engine = AVAudioEngine()
    private let session: any AudioSessioning
    private let lock = NSLock()
    private var samples: [Float] = []
    private(set) var started = Date()

    init(session: any AudioSessioning = AVAudioSession.sharedInstance()) {
        self.session = session
    }

    func activateSession() throws {
        try session.configure(.record, mode: .default)
        try session.activate(true)
    }

    func start() async throws {
        let allowed = await AVAudioApplication.requestRecordPermission()
        guard allowed else { throw RecordingError.denied }
        try activateSession()
        engine = AVAudioEngine()
        let input = engine.inputNode
        let source = input.outputFormat(forBus: 0)
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: source, to: target) else { throw RecordingError.format }
        lock.withLock { samples = [] }
        input.installTap(onBus: 0, bufferSize: 4096, format: source) { [weak self] buffer, _ in
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16000 / source.sampleRate)) + 32
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var consumed = false
            var conversionError: NSError?
            converter.convert(to: output, error: &conversionError) { _, status in
                if consumed {
                    status.pointee = .noDataNow; return nil
                }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            guard conversionError == nil, let channel = output.floatChannelData?[0] else { return }
            self?.append(Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength))))
        }
        started = Date()
        do { try engine.start() } catch { input.removeTap(onBus: 0); throw error }
    }

    private func append(_ values: [Float]) {
        lock.lock()
        samples.append(contentsOf: values)
        lock.unlock()
    }

    func stop() -> [Float] {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        try? session.activate(false)
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    enum RecordingError: LocalizedError {
        case denied, format
        var errorDescription: String? {
            switch self {
            case .denied: "Microphone access is denied. Enable it in Settings."
            case .format: "Unable to configure microphone audio."
            }
        }
    }
}
