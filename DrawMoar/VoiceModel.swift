import FluidAudio
import Foundation
import Observation
import os

struct DownloadText {
    let percent: String
    let phase: String
    let bytes: String

    init(fraction: Double, phase: DownloadPhase, downloaded: Int64, total: Int64?) {
        percent = "\(Int((fraction * 100).rounded()))%"
        switch phase {
        case .listing: self.phase = "Listing files"
        case let .downloading(completedFiles, totalFiles): self.phase = "File \(min(completedFiles + 1, totalFiles)) of \(totalFiles)"
        case .compiling: self.phase = "Compiling"
        }
        let downloadedText = ByteCountFormatter.string(fromByteCount: downloaded, countStyle: .file)
        bytes = total.map { "\(downloadedText) of \(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file))" } ?? downloadedText
    }
}

enum VoiceError: LocalizedError {
    case timedOut, notInstalled

    var errorDescription: String? {
        switch self {
        case .timedOut: "Transcription timed out"
        case .notInstalled: "Parakeet Ultra is not installed"
        }
    }
}

typealias Transcriber = ([Float]) async throws -> [NoteBuilder.Word]

private let voiceLog = Logger(subsystem: "com.noma4i.DrawMoar", category: "voice")

@MainActor @Observable final class VoiceModel {
    private(set) var installed = false
    private(set) var size: Int64 = 0
    private(set) var progress: DownloadProgress?
    private(set) var loading = false
    var error: String?
    private var transcriber: Transcriber?
    private var loadTask: Task<Void, Error>?
    private var aneTask: Task<Void, Never>?
    private var gpuTask: Task<Void, Never>?
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var generation = 0
    private var downloadTask: Task<Void, Never>?
    private let directory = AsrModels.defaultCacheDirectory(for: .ultra)
    private let loader: () async throws -> Transcriber
    private let gpuLoader: (() async throws -> Transcriber)?
    private let gpuGrace: Duration
    private let installedProbe: (() -> Bool)?

    init(loader: @escaping () async throws -> Transcriber = VoiceModel.loadInstalled, gpuLoader: (() async throws -> Transcriber)? = nil, gpuGrace: Duration = .seconds(1), installedProbe: (() -> Bool)? = nil) {
        self.loader = loader
        self.gpuLoader = gpuLoader
        self.gpuGrace = gpuGrace
        self.installedProbe = installedProbe
        refresh()
    }

    convenience init() {
        self.init(gpuLoader: VoiceModel.loadInstalledGPU)
    }

    var ready: Bool {
        transcriber != nil
    }

    func refresh() {
        installed = installedProbe?() ?? AsrModels.modelsExist(at: directory, version: .ultra)
        let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        size = files?.allObjects.compactMap { $0 as? URL }.reduce(0) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        } ?? 0
    }

    func prepare() async {
        do { try await load() } catch { self.error = error.localizedDescription }
    }

    private func load() async throws {
        guard transcriber == nil, installed else { return }
        let task: Task<Void, Error>
        if let loadTask {
            task = loadTask
        } else {
            loading = true
            generation += 1
            let current = generation
            task = Task {
                try await withCheckedThrowingContinuation { continuation in
                    readyContinuation = continuation
                    startLoaders(current)
                }
            }
            loadTask = task
        }
        try await task.value
    }

    private func startLoaders(_ current: Int) {
        let clock = ContinuousClock()
        let start = clock.now
        var pending = gpuLoader == nil ? 1 : 2
        func failed(_ error: Error) {
            guard current == generation else { return }
            pending -= 1
            if pending == 0, transcriber == nil {
                finishLoading(error)
            }
        }
        aneTask = Task {
            do {
                let loaded = try await loader()
                guard current == generation else { return }
                voiceLog.info("ane ready \(start.duration(to: clock.now).description, privacy: .public)")
                gpuTask?.cancel()
                gpuTask = nil
                if transcriber != nil {
                    voiceLog.info("swap to ane")
                }
                transcriber = loaded
                aneTask = nil
                finishLoading(nil)
            } catch { failed(error) }
        }
        guard let gpuLoader else { return }
        gpuTask = Task {
            do {
                try await Task.sleep(for: gpuGrace)
                let loaded = try await gpuLoader()
                try Task.checkCancellation()
                guard current == generation, transcriber == nil else { return }
                voiceLog.info("gpu ready \(start.duration(to: clock.now).description, privacy: .public)")
                transcriber = loaded
                gpuTask = nil
                finishLoading(nil)
            } catch is CancellationError {
            } catch { failed(error) }
        }
    }

    private func finishLoading(_ error: Error?) {
        loading = false
        loadTask = nil
        let continuation = readyContinuation
        readyContinuation = nil
        if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
    }

    func download() {
        guard downloadTask == nil else { return }
        progress = DownloadProgress(fractionCompleted: 0, phase: .listing)
        downloadTask = Task {
            let refreshTask = Task {
                while !Task.isCancelled {
                    refresh()
                    do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                }
            }
            do {
                let models = try await AsrModels.downloadAndLoad(version: .ultra) { value in
                    Task { @MainActor in
                        if self.downloadTask != nil {
                            self.progress = value
                        }
                    }
                }
                try Task.checkCancellation()
                refreshTask.cancel()
                refresh()
                progress = nil
                loading = true
                transcriber = await Self.makeTranscriber(models)
                loading = false
                error = nil
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
            refreshTask.cancel()
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
            generation += 1
            aneTask?.cancel()
            gpuTask?.cancel()
            aneTask = nil
            gpuTask = nil
            transcriber = nil
            if loadTask != nil {
                finishLoading(CancellationError())
            }
            try FileManager.default.removeItem(at: directory)
            refresh()
        } catch { self.error = error.localizedDescription }
    }

    func transcribe(_ samples: [Float]) async throws -> [NoteBuilder.Word] {
        try await load()
        guard let transcriber else { throw VoiceError.notInstalled }
        return try await transcriber(samples)
    }

    nonisolated static func loadInstalled() async throws -> Transcriber {
        let clock = ContinuousClock()
        let start = clock.now
        let models = try await AsrModels.downloadAndLoad(version: .ultra)
        voiceLog.info("model load \(start.duration(to: clock.now).description, privacy: .public)")
        return await makeTranscriber(models)
    }

    nonisolated static func loadInstalledGPU() async throws -> Transcriber {
        let models = try await AsrModels.loadFromCache(version: .ultra, encoderComputeUnits: .cpuAndGPU)
        return await makeTranscriber(models)
    }

    nonisolated static func makeTranscriber(_ models: AsrModels) async -> Transcriber {
        let manager = AsrManager(models: models)
        let clock = ContinuousClock()
        let start = clock.now
        do {
            var state = try TdtDecoderState()
            _ = try await manager.transcribe(Array(repeating: 0, count: 24000), decoderState: &state)
            voiceLog.info("prewarm \(start.duration(to: clock.now).description, privacy: .public)")
        } catch { voiceLog.error("prewarm failed \(error.localizedDescription, privacy: .public)") }
        return { samples in
            let begin = clock.now
            var state = try TdtDecoderState()
            let result = try await manager.transcribe(samples, decoderState: &state)
            voiceLog.info("transcription audio \(Double(samples.count) / 16000, format: .fixed(precision: 1), privacy: .public) s, processing \(begin.duration(to: clock.now).description, privacy: .public)")
            guard let timings = result.tokenTimings else {
                return result.text.isEmpty ? [] : [NoteBuilder.Word(text: result.text, start: 0, end: 0)]
            }
            return buildWordTimings(from: timings).map { NoteBuilder.Word(text: $0.word, start: $0.startTime, end: $0.endTime) }
        }
    }
}
