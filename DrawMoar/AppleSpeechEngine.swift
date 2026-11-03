import AVFoundation
import Foundation
import Speech

enum AppleSpeechError: LocalizedError {
    case unsupportedLocale, noAudioFormat, conversionFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedLocale: "Apple Speech does not support this language"
        case .noAudioFormat: "Apple Speech has no compatible audio format"
        case .conversionFailed: "Could not convert audio for Apple Speech"
        }
    }
}

enum AppleSpeechEngine {
    struct Run: Equatable {
        let text: String
        let start: Double
        let end: Double
    }

    static func identifier(_ locale: Locale) -> String {
        locale.identifier(.bcp47)
    }

    static func supportedIdentifiers() async -> [String] {
        await SpeechTranscriber.supportedLocales.map(identifier).sorted()
    }

    static func installedIdentifiers() async -> Set<String> {
        Set(await SpeechTranscriber.installedLocales.map(identifier))
    }

    static func language(supported: [String], preferred: [String]) -> String? {
        for candidate in preferred {
            let tag = identifier(Locale(identifier: candidate))
            if supported.contains(tag) {
                return tag
            }
        }
        for candidate in preferred {
            let code = Locale(identifier: candidate).language.languageCode?.identifier
            if let match = supported.first(where: { Locale(identifier: $0).language.languageCode?.identifier == code }) {
                return match
            }
        }
        return nil
    }

    static func words(from runs: [Run]) -> [NoteBuilder.Word] {
        runs.compactMap { run in
            let text = run.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : NoteBuilder.Word(text: text, start: run.start, end: run.end)
        }
    }

    private static func makeTranscriber(_ language: String) -> SpeechTranscriber {
        SpeechTranscriber(locale: Locale(identifier: language), transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
    }

    static func download(language: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        let transcriber = makeTranscriber(language)
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else { return }
        let observer = Task {
            while !Task.isCancelled {
                progress(request.progress.fractionCompleted)
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
        }
        defer { observer.cancel() }
        try await withTaskCancellationHandler {
            try await request.downloadAndInstall()
        } onCancel: {
            request.progress.cancel()
        }
    }

    static func load(language: String) async throws -> Transcriber {
        guard await SpeechTranscriber.supportedLocales.contains(where: { identifier($0) == language }) else { throw AppleSpeechError.unsupportedLocale }
        let warm = makeTranscriber(language)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [warm]) else { throw AppleSpeechError.noAudioFormat }
        try await SpeechAnalyzer(modules: [warm]).prepareToAnalyze(in: format)
        return { samples in
            let transcriber = makeTranscriber(language)
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { throw AppleSpeechError.noAudioFormat }
            let buffer = try convert(samples, to: format)
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let collector = Task {
                var runs: [Run] = []
                for try await result in transcriber.results {
                    for run in result.text.runs {
                        guard let range = run.audioTimeRange else { continue }
                        runs.append(Run(text: String(result.text[run.range].characters), start: range.start.seconds, end: range.end.seconds))
                    }
                }
                return runs
            }
            let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
            continuation.yield(AnalyzerInput(buffer: buffer))
            continuation.finish()
            do {
                _ = try await analyzer.analyzeSequence(stream)
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                collector.cancel()
                throw error
            }
            return try await words(from: collector.value)
        }
    }

    private static func convert(_ samples: [Float], to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(samples.count)),
              let converter = AVAudioConverter(from: source, to: format)
        else { throw AppleSpeechError.conversionFailed }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { input.floatChannelData?[0].update(from: $0.baseAddress!, count: samples.count) }
        let capacity = AVAudioFrameCount(Double(samples.count) * format.sampleRate / 16000) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { throw AppleSpeechError.conversionFailed }
        var supplied = false
        var failure: NSError?
        converter.convert(to: output, error: &failure) { _, status in
            if supplied {
                status.pointee = .endOfStream
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
        if let failure {
            throw failure
        }
        return output
    }
}
