import AVFoundation
import CoreMedia
import Speech

enum TranscriptionError: LocalizedError {
    case unsupportedLanguage(String)
    var errorDescription: String? {
        switch self {
        case .unsupportedLanguage(let id): return "On-device transcription doesn't support \(id)"
        }
    }
}

/// On-device streaming transcription of one audio source (macOS 26 SpeechAnalyzer).
final class LiveTranscriber {
    let speaker: Speaker
    var onFinal: ((Segment) -> Void)?
    var onVolatile: ((String) -> Void)?

    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var targetFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var converterSource: AVAudioFormat?
    private let queue = DispatchQueue(label: "aistack.transcriber")
    private var streamStart: Date?

    init(speaker: Speaker) { self.speaker = speaker }

    /// Resolves the closest supported locale and downloads its model if needed.
    static func prepareModel(for identifier: String) async throws -> Locale {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier)) else {
            throw TranscriptionError.unsupportedLanguage(identifier)
        }
        let probe = SpeechTranscriber(locale: locale, preset: .transcription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
            Log.info("Downloading speech model for \(locale.identifier)", "transcribe")
            try await request.downloadAndInstall()
        }
        return locale
    }

    static func isModelInstalled(_ identifier: String) async -> Bool {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier)) else { return false }
        let installed = await SpeechTranscriber.installedLocales
        return installed.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
    }

    func start(languageID: String) async throws {
        let locale = try await Self.prepareModel(for: languageID)
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults],
                                            attributeOptions: [.audioTimeRange])
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        queue.sync {
            self.targetFormat = format
            self.continuation = continuation
        }
        self.analyzer = analyzer

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    if result.isFinal {
                        self.onVolatile?("")
                        guard !text.isEmpty, let start = self.queue.sync(execute: { self.streamStart }) else { continue }
                        let segment = Segment(speaker: self.speaker,
                                              start: start.addingTimeInterval(result.range.start.seconds),
                                              end: start.addingTimeInterval(result.range.end.seconds),
                                              text: text)
                        self.onFinal?(segment)
                    } else {
                        self.onVolatile?(text)
                    }
                }
            } catch {
                Log.error("Transcriber (\(self?.speaker.rawValue ?? "?")) stopped: \(error.localizedDescription)", "transcribe")
            }
        }
        try await analyzer.start(inputSequence: stream)
        Log.info("Transcriber \(speaker.rawValue) started (\(locale.identifier), \(format?.description ?? "default format"))", "transcribe")
    }

    /// Feed audio from any thread. The buffer must be owned by the caller (see deepCopy()).
    func append(_ buffer: AVAudioPCMBuffer) {
        queue.async { [weak self] in
            guard let self, let continuation = self.continuation else { return }
            if self.streamStart == nil {
                self.streamStart = Date().addingTimeInterval(-Double(buffer.frameLength) / buffer.format.sampleRate)
            }
            guard let converted = self.convert(buffer) else { return }
            continuation.yield(AnalyzerInput(buffer: converted))
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let target = targetFormat else { return buffer }
        if buffer.format == target { return buffer }
        if converter == nil || converterSource != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            converter?.downmix = true
            converterSource = buffer.format
        }
        guard let converter else { return nil }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error {
            Log.error("Audio conversion failed: \(error?.localizedDescription ?? "?")", "transcribe")
            return nil
        }
        return output.frameLength > 0 ? output : nil
    }

    /// Flushes remaining audio and waits for the last results.
    func finish() async {
        let continuation: AsyncStream<AnalyzerInput>.Continuation? = queue.sync {
            let c = self.continuation
            self.continuation = nil
            return c
        }
        continuation?.finish()
        do {
            try await analyzer?.finalizeAndFinishThroughEndOfInput()
        } catch {
            Log.error("Finalize failed: \(error.localizedDescription)", "transcribe")
        }
        await resultsTask?.value
    }
}
