import AVFoundation
import Speech

/// SpeechTranscriber 会交替发布可变结果和最终结果；这里只保留一个可变尾段，
/// 最终结果按系统给出的顺序拼接，避免实时刷新时把同一段文字重复插入草稿。
struct AppleSpeechTranscriptAccumulator: Equatable {
    private(set) var finalizedText = ""
    private(set) var volatileText = ""

    var text: String {
        finalizedText + volatileText
    }

    mutating func apply(_ text: String, isFinal: Bool) {
        if isFinal {
            // 最终结果可能为空（系统撤回一段噪声误识别）；此时也必须清掉旧的 volatile 文本。
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                finalizedText += text
            }
            volatileText = ""
        } else if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            volatileText = text
        }
    }
}

enum AppleSpeechTranscriptionError: LocalizedError {
    case unsupportedLocale
    case audioFormatUnavailable
    case audioConversionFailed
    case recordingFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedLocale:
            return L10n.text("ui.apple_voice_input_does_not_support_the_current_language")
        case .audioFormatUnavailable:
            return L10n.text("ui.apple_voice_input_audio_format_is_unavailable")
        case .audioConversionFailed:
            return L10n.text("ui.apple_voice_input_audio_conversion_failed")
        case .recordingFailed:
            return L10n.text("ui.apple_voice_input_could_not_start_recording")
        }
    }
}

/// iOS 26 的 SpeechAnalyzer 只负责分析，实时麦克风采集仍由 App 管理。
/// 该对象限定在主线程持有生命周期；音频 tap 里只做同步格式转换和 AsyncStream yield。
@MainActor
final class AppleSpeechTranscriptionSession {
    private var analyzer: SpeechAnalyzer?
    private var audioEngine: AVAudioEngine?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var isFinishing = false

    func start(
        locale: Locale,
        onTranscript: @escaping @MainActor (String) -> Void,
        onLevel: @escaping @MainActor (CGFloat) -> Void,
        onFailure: @escaping @MainActor (Error) -> Void
    ) async throws {
        guard analyzer == nil, audioEngine == nil else {
            throw AppleSpeechTranscriptionError.recordingFailed
        }
        guard let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw AppleSpeechTranscriptionError.unsupportedLocale
        }

        let transcriber = SpeechTranscriber(locale: supportedLocale, preset: .progressiveTranscription)
        let modules: [any SpeechModule] = [transcriber]
        if let installationRequest = try await AssetInventory.assetInstallationRequest(supporting: modules) {
            try await installationRequest.downloadAndInstall()
        }
        try Task.checkCancellation()

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
            throw AppleSpeechTranscriptionError.audioFormatUnavailable
        }
        let analyzer = SpeechAnalyzer(modules: modules)
        try await analyzer.prepareToAnalyze(in: analyzerFormat)
        try Task.checkCancellation()

        let (inputSequence, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.analyzer = analyzer
        inputContinuation = continuation
        isFinishing = false

        resultsTask = Task { [weak self] in
            var accumulator = AppleSpeechTranscriptAccumulator()
            do {
                for try await result in transcriber.results {
                    guard !Task.isCancelled else { return }
                    accumulator.apply(String(result.text.characters), isFinal: result.isFinal)
                    let transcript = accumulator.text
                    if !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        onTranscript(transcript)
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                guard self?.isFinishing != true else {
                    return
                }
                onFailure(error)
            }
        }

        try await analyzer.start(inputSequence: inputSequence)
        do {
            try startAudioCapture(
                analyzerFormat: analyzerFormat,
                continuation: continuation,
                onLevel: onLevel,
                onFailure: onFailure
            )
        } catch {
            await cancel()
            throw error
        }
    }

    func finish() async throws {
        guard let analyzer else {
            return
        }
        isFinishing = true
        stopAudioCapture()
        inputContinuation?.finish()
        inputContinuation = nil
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        await resultsTask?.value
        reset()
    }

    func cancel() async {
        isFinishing = true
        stopAudioCapture()
        inputContinuation?.finish()
        inputContinuation = nil
        resultsTask?.cancel()
        if let analyzer {
            await analyzer.cancelAndFinishNow()
        }
        reset()
    }

    private func startAudioCapture(
        analyzerFormat: AVAudioFormat,
        continuation: AsyncStream<AnalyzerInput>.Continuation,
        onLevel: @escaping @MainActor (CGFloat) -> Void,
        onFailure: @escaping @MainActor (Error) -> Void
    ) throws {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0,
              inputFormat.channelCount > 0,
              let converter = AppleSpeechAudioBufferConverter(from: inputFormat, to: analyzerFormat)
        else {
            throw AppleSpeechTranscriptionError.audioFormatUnavailable
        }

        var didFailConversion = false
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { buffer, _ in
            guard !didFailConversion else { return }
            do {
                let converted = try converter.convert(buffer)
                continuation.yield(AnalyzerInput(buffer: converted))
                let level = AppleSpeechAudioLevel.normalizedPower(from: buffer)
                Task { @MainActor in
                    onLevel(level)
                }
            } catch {
                guard !didFailConversion else { return }
                didFailConversion = true
                continuation.finish()
                Task { @MainActor in
                    onFailure(error)
                }
            }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw AppleSpeechTranscriptionError.recordingFailed
        }
        audioEngine = engine
    }

    private func stopAudioCapture() {
        guard let audioEngine else {
            return
        }
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        self.audioEngine = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func reset() {
        resultsTask?.cancel()
        resultsTask = nil
        analyzer = nil
        isFinishing = false
    }
}

/// Xcode 26 没有 AnalyzerInputConverter，使用 AVAudioConverter 保持 iOS 26 最低版本兼容。
private final class AppleSpeechAudioBufferConverter: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat

    init?(from inputFormat: AVAudioFormat, to outputFormat: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            return nil
        }
        self.converter = converter
        self.outputFormat = outputFormat
    }

    func convert(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let estimatedFrames = max(1, ceil(Double(input.frameLength) * ratio))
        guard let output = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: AVAudioFrameCount(estimatedFrames)
        ) else {
            throw AppleSpeechTranscriptionError.audioConversionFailed
        }

        var conversionError: NSError?
        var suppliedInput = false
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            guard !suppliedInput else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return input
        }
        if let conversionError {
            throw conversionError
        }
        guard status == .haveData || status == .inputRanDry else {
            throw AppleSpeechTranscriptionError.audioConversionFailed
        }
        return output
    }
}

private enum AppleSpeechAudioLevel {
    static func normalizedPower(from buffer: AVAudioPCMBuffer) -> CGFloat {
        guard let channelData = buffer.floatChannelData?[0] else {
            return 0
        }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else {
            return 0
        }
        var sumSquares: Float = 0
        for index in 0..<frameLength {
            let sample = channelData[index]
            sumSquares += sample * sample
        }
        let rms = sqrt(sumSquares / Float(frameLength))
        let decibels = 20 * log10(max(rms, 0.000_000_1))
        let clamped = max(-60, min(0, decibels))
        return CGFloat((clamped + 60) / 60)
    }
}
