import Foundation
import WhisperKit

enum WhisperEngine {
    static let variant = "openai_whisper-small_216MB"
    private static let base = URL.applicationSupportDirectory.appending(path: "DrawMoar/whisper", directoryHint: .isDirectory)
    static let directory = base.appending(path: "models/argmaxinc/whisperkit-coreml/\(variant)", directoryHint: .isDirectory)

    static func installed() -> Bool {
        ["AudioEncoder.mlmodelc", "MelSpectrogram.mlmodelc", "TextDecoder.mlmodelc"].allSatisfy {
            FileManager.default.fileExists(atPath: directory.appending(path: $0).path)
        }
    }

    static func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        _ = try await WhisperKit.download(variant: variant, downloadBase: base) { value in
            progress(value.fractionCompleted)
        }
        guard installed() else { throw CocoaError(.fileNoSuchFile) }
    }

    static func load() async throws -> Transcriber {
        let kit = try await WhisperKit(WhisperKitConfig(modelFolder: directory.path, verbose: false, logLevel: .none, prewarm: true, load: true, download: false))
        let options = DecodingOptions(task: .transcribe, language: nil, usePrefillPrompt: true, detectLanguage: true, wordTimestamps: true)
        return { samples in
            let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
            return words(from: results.flatMap(\.segments))
        }
    }

    static func words(from segments: [TranscriptionSegment]) -> [NoteBuilder.Word] {
        segments.flatMap { segment -> [NoteBuilder.Word] in
            if let words = segment.words, !words.isEmpty {
                return words.compactMap { timing in
                    let text = timing.word.trimmingCharacters(in: .whitespacesAndNewlines)
                    return text.isEmpty ? nil : NoteBuilder.Word(text: text, start: Double(timing.start), end: Double(timing.end))
                }
            }
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? [] : [NoteBuilder.Word(text: text, start: Double(segment.start), end: Double(segment.end))]
        }
    }
}
