import FluidAudio
import Foundation
import Observation

@MainActor @Observable final class VoiceModel {
    private(set) var installed = false
    private(set) var size: Int64 = 0
    private(set) var progress: Double?
    var error: String?
    private var manager: AsrManager?
    private var downloadTask: Task<Void, Never>?
    private let directory = AsrModels.defaultCacheDirectory(for: .ultra)

    init() {
        refresh()
    }

    func refresh() {
        installed = AsrModels.modelsExist(at: directory, version: .ultra)
        let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        size = files?.allObjects.compactMap { $0 as? URL }.reduce(0) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        } ?? 0
    }

    func download() {
        guard downloadTask == nil else { return }
        progress = 0
        downloadTask = Task {
            do {
                let models = try await AsrModels.downloadAndLoad(version: .ultra) { value in
                    Task { @MainActor in self.progress = value.fractionCompleted }
                }
                try Task.checkCancellation()
                manager = AsrManager(models: models)
                error = nil
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
            refresh()
            progress = nil
            downloadTask = nil
        }
    }

    func cancel() {
        downloadTask?.cancel()
    }

    func delete() {
        do {
            manager = nil
            try FileManager.default.removeItem(at: directory)
            refresh()
        } catch { self.error = error.localizedDescription }
    }

    func transcribe(_ samples: [Float]) async throws -> [NoteBuilder.Word] {
        let active: AsrManager
        if let manager {
            active = manager
        } else {
            let models = try await AsrModels.downloadAndLoad(version: .ultra)
            active = AsrManager(models: models)
            manager = active
        }
        var state = try TdtDecoderState()
        let result = try await active.transcribe(samples, decoderState: &state)
        guard let timings = result.tokenTimings else {
            return result.text.isEmpty ? [] : [NoteBuilder.Word(text: result.text, start: 0, end: 0)]
        }
        return buildWordTimings(from: timings).map { NoteBuilder.Word(text: $0.word, start: $0.startTime, end: $0.endTime) }
    }
}
