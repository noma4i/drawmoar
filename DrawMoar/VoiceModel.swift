import FluidAudio
import Foundation
import Observation
import os

struct VoiceProgress: Equatable {
    var fraction: Double
    var phase: String

    init(fraction: Double, phase: String) {
        self.fraction = fraction
        self.phase = phase
    }

    init(_ value: DownloadProgress) {
        self.init(fraction: value.fractionCompleted, phase: DownloadText.phaseText(value.phase))
    }
}

struct DownloadText {
    let percent: String
    let phase: String
    let bytes: String

    init(fraction: Double, phase: DownloadPhase, downloaded: Int64, total: Int64?) {
        self.init(fraction: fraction, phaseText: Self.phaseText(phase), downloaded: downloaded, total: total)
    }

    init(fraction: Double, phaseText: String, downloaded: Int64, total: Int64?) {
        percent = "\(Int((fraction * 100).rounded()))%"
        phase = phaseText
        let downloadedText = ByteCountFormatter.string(fromByteCount: downloaded, countStyle: .file)
        bytes = total.map { "\(downloadedText) of \(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file))" } ?? downloadedText
    }

    static func phaseText(_ phase: DownloadPhase) -> String {
        switch phase {
        case .listing: "Listing files"
        case let .downloading(completedFiles, totalFiles): "File \(min(completedFiles + 1, totalFiles)) of \(totalFiles)"
        case .compiling: "Compiling"
        }
    }
}

enum VoiceEngine: String, CaseIterable, Identifiable {
    case apple, parakeet, whisper

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .apple: "Apple Speech"
        case .parakeet: "Parakeet Ultra"
        case .whisper: "Whisper Small"
        }
    }
}

enum VoiceError: LocalizedError {
    case timedOut, notInstalled

    var errorDescription: String? {
        switch self {
        case .timedOut: "Transcription timed out"
        case .notInstalled: "The voice model is not installed"
        }
    }
}

typealias Transcriber = ([Float]) async throws -> [NoteBuilder.Word]

enum VoiceSignal {
    static let silenceThreshold: Float = 1e-4
    static let silentMessage = "No audio recorded. Check the microphone."

    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        return (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }
}

enum SpeechTokens {
    private static let maxMarkerWords = 4

    static func clean(_ words: [NoteBuilder.Word]) -> [NoteBuilder.Word] {
        var result: [NoteBuilder.Word] = []
        var closer: Character?
        var span = 0
        for word in words {
            var kept = ""
            if closer != nil {
                span += 1
                if span > maxMarkerWords {
                    closer = nil
                }
            }
            for character in word.text.replacingOccurrences(of: "<\\|[^|>]*\\|>", with: "", options: .regularExpression) {
                if let expected = closer {
                    if character == expected {
                        closer = nil
                    }
                } else if character == "[" || character == "(" {
                    closer = character == "[" ? "]" : ")"
                    span = 0
                } else {
                    kept.append(character)
                }
            }
            let text = kept.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                result.append(NoteBuilder.Word(text: text, start: word.start, end: word.end))
            }
        }
        return result
    }
}

let voiceLog = Logger(subsystem: "com.noma4i.DrawMoar", category: "voice")

@MainActor @Observable final class VoiceModel {
    private(set) var engine: VoiceEngine
    private(set) var language = ""
    private(set) var appleLanguages: [String] = []
    private(set) var installedEngines: Set<VoiceEngine> = []
    private(set) var size: Int64 = 0
    private(set) var progress: VoiceProgress?
    private(set) var loading = false
    var error: String?
    private var transcriber: Transcriber?
    private var loadTask: Task<Void, Error>?
    private var downloadTask: Task<Void, Never>?
    private var generation = 0
    private var appleInstalledIDs: Set<String> = []
    private var appleReady = false
    private let defaults: UserDefaults
    private let directory = AsrModels.defaultCacheDirectory(for: .ultra)
    private let parakeetLoader: () async throws -> Transcriber
    private let parakeetProbe: (() -> Bool)?
    private let appleLoader: (String) async throws -> Transcriber
    private let whisperLoader: () async throws -> Transcriber
    private let whisperProbe: (() -> Bool)?

    init(defaults: UserDefaults = .standard, loader: @escaping () async throws -> Transcriber = VoiceModel.loadInstalled, installedProbe: (() -> Bool)? = nil, appleLoader: @escaping (String) async throws -> Transcriber = AppleSpeechEngine.load, appleSupported: [String]? = nil, appleInstalled: Set<String> = [], whisperLoader: @escaping () async throws -> Transcriber = WhisperEngine.load, whisperProbe: (() -> Bool)? = nil) {
        self.defaults = defaults
        parakeetLoader = loader
        parakeetProbe = installedProbe
        self.appleLoader = appleLoader
        self.whisperLoader = whisperLoader
        self.whisperProbe = whisperProbe
        engine = defaults.string(forKey: Self.engineKey).flatMap(VoiceEngine.init) ?? .parakeet
        appleInstalledIDs = appleInstalled
        if let appleSupported {
            applyApple(supported: appleSupported)
        }
        refresh()
    }

    private static let engineKey = "voiceEngine"
    private static let languageKey = "voiceLanguage"

    var installed: Bool {
        installedEngines.contains(engine)
    }

    var ready: Bool {
        transcriber != nil
    }

    private func applyApple(supported: [String]) {
        appleReady = true
        appleLanguages = supported
        let preferred = Locale.preferredLanguages
        let match = AppleSpeechEngine.language(supported: supported, preferred: preferred)
        let stored = defaults.string(forKey: Self.languageKey).flatMap { supported.contains($0) ? $0 : nil }
        language = stored ?? match ?? (supported.contains("en-US") ? "en-US" : supported.first ?? "")
        if defaults.string(forKey: Self.engineKey) == nil, match != nil {
            engine = .apple
        }
    }

    func refreshApple() async {
        if !appleReady {
            applyApple(supported: await AppleSpeechEngine.supportedIdentifiers())
        }
        appleInstalledIDs = await AppleSpeechEngine.installedIdentifiers()
        refresh()
    }

    func refresh() {
        var found: Set<VoiceEngine> = []
        if parakeetProbe?() ?? AsrModels.modelsExist(at: directory, version: .ultra) {
            found.insert(.parakeet)
        }
        if whisperProbe?() ?? WhisperEngine.installed() {
            found.insert(.whisper)
        }
        if appleInstalledIDs.contains(language) {
            found.insert(.apple)
        }
        installedEngines = found
        switch engine {
        case .apple: size = 0
        case .parakeet: size = Self.folderSize(directory)
        case .whisper: size = Self.folderSize(WhisperEngine.directory)
        }
    }

    private static func folderSize(_ url: URL) -> Int64 {
        let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        return files?.allObjects.compactMap { $0 as? URL }.reduce(0) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        } ?? 0
    }

    private func release() {
        generation += 1
        loadTask?.cancel()
        loadTask = nil
        downloadTask?.cancel()
        transcriber = nil
        loading = false
        progress = nil
        error = nil
    }

    func select(_ newEngine: VoiceEngine) {
        guard newEngine != engine else { return }
        release()
        engine = newEngine
        defaults.set(newEngine.rawValue, forKey: Self.engineKey)
        refresh()
    }

    func setLanguage(_ identifier: String) {
        guard identifier != language else { return }
        release()
        language = identifier
        defaults.set(identifier, forKey: Self.languageKey)
        refresh()
    }

    func prepare() async {
        await refreshApple()
        do { try await load() } catch { self.error = error.localizedDescription }
    }

    private func load() async throws {
        guard transcriber == nil, installed else { return }
        let task: Task<Void, Error>
        if let loadTask {
            task = loadTask
        } else {
            loading = true
            let token = generation
            let engine = engine
            let language = language
            task = Task {
                defer {
                    if token == generation {
                        loading = false
                        loadTask = nil
                    }
                }
                let loaded: Transcriber = switch engine {
                case .apple: try await appleLoader(language)
                case .parakeet: try await parakeetLoader()
                case .whisper: try await whisperLoader()
                }
                try Task.checkCancellation()
                guard token == generation else { return }
                transcriber = loaded
            }
            loadTask = task
        }
        try await task.value
    }

    private func setProgress(_ value: VoiceProgress, token: Int) {
        if token == generation, downloadTask != nil {
            progress = value
        }
    }

    func download() {
        guard downloadTask == nil else { return }
        let token = generation
        let engine = engine
        let language = language
        progress = VoiceProgress(fraction: 0, phase: engine == .parakeet ? "Listing files" : "Downloading")
        downloadTask = Task {
            let refreshTask = Task {
                while !Task.isCancelled {
                    refresh()
                    do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                }
            }
            do {
                let finish: () async throws -> Transcriber
                switch engine {
                case .parakeet:
                    let models = try await AsrModels.downloadAndLoad(version: .ultra) { value in
                        Task { @MainActor in self.setProgress(VoiceProgress(value), token: token) }
                    }
                    finish = { await Self.makeTranscriber(models) }
                case .whisper:
                    try await WhisperEngine.download { value in
                        Task { @MainActor in self.setProgress(VoiceProgress(fraction: value, phase: "Downloading"), token: token) }
                    }
                    finish = whisperLoader
                case .apple:
                    try await AppleSpeechEngine.download(language: language) { value in
                        Task { @MainActor in self.setProgress(VoiceProgress(fraction: value, phase: "Downloading"), token: token) }
                    }
                    finish = { [appleLoader] in try await appleLoader(language) }
                }
                try Task.checkCancellation()
                refreshTask.cancel()
                if engine == .apple {
                    appleInstalledIDs = await AppleSpeechEngine.installedIdentifiers()
                }
                refresh()
                progress = nil
                loading = true
                let loaded = try await finish()
                if token == generation {
                    transcriber = loaded
                    error = nil
                }
            } catch is CancellationError {
            } catch {
                if token == generation {
                    self.error = error.localizedDescription
                }
            }
            refreshTask.cancel()
            if token == generation {
                loading = false
                progress = nil
            }
            refresh()
            downloadTask = nil
        }
    }

    func cancel() {
        downloadTask?.cancel()
    }

    func delete() {
        do {
            generation += 1
            loadTask?.cancel()
            loadTask = nil
            transcriber = nil
            loading = false
            switch engine {
            case .apple: break
            case .parakeet: try FileManager.default.removeItem(at: directory)
            case .whisper: try FileManager.default.removeItem(at: WhisperEngine.directory)
            }
            refresh()
        } catch { self.error = error.localizedDescription }
    }

    func transcribe(_ samples: [Float]) async throws -> [NoteBuilder.Word] {
        try await load()
        guard let transcriber else { throw VoiceError.notInstalled }
        return try await SpeechTokens.clean(transcriber(samples))
    }

    nonisolated static func loadInstalled() async throws -> Transcriber {
        let clock = ContinuousClock()
        let start = clock.now
        let models = try await AsrModels.downloadAndLoad(version: .ultra)
        voiceLog.info("model load \(start.duration(to: clock.now).description, privacy: .public)")
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
