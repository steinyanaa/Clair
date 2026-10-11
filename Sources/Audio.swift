import Foundation
@preconcurrency import AVFoundation
import Speech
import ScreenCaptureKit
import CoreMedia

enum AudioSource: String, CaseIterable, Identifiable {
    case microphone = "麦克风"
    case system = "系统声音"
    var id: String { rawValue }
    var symbol: String { self == .microphone ? "mic.fill" : "speaker.wave.2.fill" }
}

struct SpeechEvent: Sendable {
    let start: Double
    let duration: Double
    let text: String
    let isFinal: Bool
    /// Mean recogniser confidence (0–1), weighted by text length; nil if not reported.
    var confidence: Double? = nil
    /// Words the recogniser was unsure of, for highlighting.
    var uncertainWords: [String] = []
    /// Every recognised word with its confidence (diagnostics and tests).
    var wordConfidences: [(String, Double)] = []
}

struct AppError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

// Capture callbacks run on audio queues. Own every buffer before leaving them;
// convert serially and send monotonically timed PCM to SpeechAnalyzer.
final class AudioSink: @unchecked Sendable {
    let format: AVAudioFormat
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let queue = DispatchQueue(label: "ClairClass.audio.convert")
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var frames: Int64 = 0
    private var closed = false
    private let meter: @Sendable (Float) -> Void
    private let failure: @Sendable (String) -> Void

    init(format: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation,
         meter: @escaping @Sendable (Float) -> Void,
         failure: @escaping @Sendable (String) -> Void) {
        self.format = format
        self.continuation = continuation
        self.meter = meter
        self.failure = failure
    }

    func accept(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0,
              let owned = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return }
        owned.frameLength = buffer.frameLength
        let from = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let to = UnsafeMutableAudioBufferListPointer(owned.mutableAudioBufferList)
        for index in 0..<min(from.count, to.count) {
            if let src = from[index].mData, let dst = to[index].mData {
                memcpy(dst, src, Int(from[index].mDataByteSize))
            }
        }
        queue.async { [self] in
            guard !closed else { return }
            if inputFormat != owned.format {
                inputFormat = owned.format
                converter = AVAudioConverter(from: owned.format, to: format)
            }
            let capacity = AVAudioFrameCount(Double(owned.frameLength) * format.sampleRate / owned.format.sampleRate + 256)
            guard let converter, let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
                failure("无法转换当前音源的音频格式。")
                return
            }
            var supplied = false
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                if supplied { inputStatus.pointee = .noDataNow; return nil }
                supplied = true
                inputStatus.pointee = .haveData
                return owned
            }
            guard status != .error, error == nil else {
                failure("音频转换失败：\(error?.localizedDescription ?? "未知错误")")
                return
            }
            guard output.frameLength > 0 else { return }
            if let samples = output.floatChannelData?[0] {
                var sum: Float = 0
                for i in 0..<Int(output.frameLength) { sum += samples[i] * samples[i] }
                meter(min(1, sqrt(sum / Float(output.frameLength)) * 7))
            }
            let time = CMTime(value: frames, timescale: Int32(format.sampleRate))
            frames += Int64(output.frameLength)
            continuation.yield(AnalyzerInput(buffer: output, bufferStartTime: time))
        }
    }

    func accept(_ sample: CMSampleBuffer) {
        guard sample.isValid, CMSampleBufferDataIsReady(sample),
              let description = CMSampleBufferGetFormatDescription(sample) else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))) else { return }
        pcm.frameLength = pcm.frameCapacity
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0,
                      frameCount: Int32(pcm.frameLength), into: pcm.mutableAudioBufferList)
        guard status == noErr else { failure("系统音频读取失败。请重新选择音源。"); return }
        accept(pcm)
    }

    func finish() async {
        await withCheckedContinuation { done in
            queue.async { [self] in
                closed = true
                continuation.finish()
                done.resume()
            }
        }
    }
}

final class SystemAudioOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let sink: AudioSink
    let failure: @Sendable (String) -> Void
    init(sink: AudioSink, failure: @escaping @Sendable (String) -> Void) {
        self.sink = sink; self.failure = failure
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio { sink.accept(sampleBuffer) }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        failure("系统声音已中断：\(error.localizedDescription)")
    }
}

@MainActor
final class SpeechCapture {
    private var engine: AVAudioEngine?
    private var systemStream: SCStream?
    private var systemOutput: SystemAudioOutput?
    private var sink: AudioSink?
    private var analyzer: SpeechAnalyzer?
    private var resultsTask: Task<Void, Never>?
    private var fileTask: Task<Void, Never>?

    static func prepareFrench() async throws {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "fr-FR")) else {
            throw AppError("这台 Mac 的 Apple Speech 暂不支持法语实时转写。需要 macOS 26 或更新版本。")
        }
        let module = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
        _ = try await AssetInventory.reserve(locale: locale)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
    }

    func start(source: AudioSource, event: @escaping @MainActor @Sendable (SpeechEvent) -> Void,
               meter: @escaping @MainActor @Sendable (Float) -> Void,
               failure: @escaping @MainActor @Sendable (String) -> Void) async throws {
        if source == .microphone {
            let allowed = await AVCaptureDevice.requestAccess(for: .audio)
            guard allowed else { throw AppError("请在系统设置 → 隐私与安全性 → 麦克风中允许「法语听课助手」。") }
        }
        try await setup(event: event, meter: meter, failure: failure)
        guard let sink else { throw AppError("语音识别尚未准备好。") }
        do {
            if source == .microphone {
                let engine = AVAudioEngine()
                let input = engine.inputNode
                let format = input.outputFormat(forBus: 0)
                guard format.sampleRate > 0, format.channelCount > 0 else { throw AppError("没有可用的麦克风。") }
                input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in sink.accept(buffer) }
                self.engine = engine
                engine.prepare()
                try engine.start()
            } else {
                let content: SCShareableContent
                do { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
                catch { throw AppError("请在系统设置 → 隐私与安全性 → 屏幕与系统音频录制中允许「法语听课助手」，然后重新打开 App。") }
                guard let display = content.displays.first else { throw AppError("未找到可采集声音的显示器。") }
                let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
                let configuration = SCStreamConfiguration()
                configuration.capturesAudio = true
                configuration.excludesCurrentProcessAudio = true
                configuration.sampleRate = 48000
                configuration.channelCount = 2
                // Receive audio only. No video output is attached or retained.
                configuration.width = 2
                configuration.height = 2
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                let output = SystemAudioOutput(sink: sink) { message in Task { @MainActor in failure(message) } }
                let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
                try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: DispatchQueue(label: "ClairClass.system.audio"))
                systemOutput = output; systemStream = stream
                try await stream.startCapture()
            }
        } catch {
            await stop()
            throw error
        }
    }

    private func setup(event: @escaping @MainActor @Sendable (SpeechEvent) -> Void,
                       meter: @escaping @MainActor @Sendable (Float) -> Void,
                       failure: @escaping @MainActor @Sendable (String) -> Void) async throws {
        try await Self.prepareFrench()
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "fr-FR")) else {
            throw AppError("法语识别资源不可用。")
        }
        // Same behaviour as the time-indexed progressive preset, plus confidence.
        let preset = SpeechTranscriber.Preset.timeIndexedProgressiveTranscription
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: preset.transcriptionOptions,
                                            reportingOptions: preset.reportingOptions,
                                            attributeOptions: preset.attributeOptions.union([.transcriptionConfidence]))
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw AppError("没有可用的语音识别音频格式。")
        }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let sink = AudioSink(format: format, continuation: continuation,
            meter: { level in Task { @MainActor in meter(level) } },
            failure: { message in Task { @MainActor in failure(message) } })
        self.sink = sink; self.analyzer = analyzer
        resultsTask = Task { @MainActor in
            do {
                for try await result in transcriber.results {
                    guard !Task.isCancelled else { break }
                    let words = Self.wordConfidences(in: result.text)
                    event(SpeechEvent(start: result.range.start.seconds, duration: result.range.duration.seconds,
                         text: String(result.text.characters), isFinal: result.isFinal,
                         confidence: Self.confidence(of: result.text),
                         uncertainWords: words.filter { $0.1 < TranscriptRules.uncertainWord && TranscriptRules.isContentWord($0.0) }.map(\.0),
                         wordConfidences: words))
                }
            } catch {
                if !Task.isCancelled { failure("法语转写中断：\(error.localizedDescription)") }
            }
        }
        try await analyzer.prepareToAnalyze(in: format)
        try await analyzer.start(inputSequence: stream)
    }

    static func confidence(of text: AttributedString) -> Double? {
        var weighted = 0.0, total = 0
        for run in text.runs {
            guard let value = run[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self] else { continue }
            let count = text.characters[run.range].count
            weighted += value * Double(count); total += count
        }
        return total > 0 ? weighted / Double(total) : nil
    }

    static func wordConfidences(in text: AttributedString) -> [(String, Double)] {
        text.runs.compactMap { run in
            guard let value = run[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self] else { return nil }
            let word = String(text.characters[run.range]).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            return word.isEmpty ? nil : (word, value)
        }
    }

    // Imported files use exactly the same capture/conversion/recognition path.
    func transcribeFile(_ url: URL, realtime: Bool = false,
                        event: @escaping @MainActor @Sendable (SpeechEvent) -> Void,
                        failure: @escaping @MainActor @Sendable (String) -> Void,
                        completed: @escaping @MainActor @Sendable () -> Void) async throws {
        try await setup(event: event, meter: { _ in }, failure: failure)
        guard let sink else { return }
        let file = try AVAudioFile(forReading: url)
        fileTask = Task { @MainActor [weak self] in
            do {
                while file.framePosition < file.length && !Task.isCancelled {
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else { break }
                    try file.read(into: buffer)
                    sink.accept(buffer)
                    if realtime { try await Task.sleep(for: .seconds(Double(buffer.frameLength) / file.processingFormat.sampleRate)) }
                    else { try await Task.sleep(for: .milliseconds(1)) }
                }
                guard !Task.isCancelled else { return }
                await self?.stop(cancelFile: false)
                completed()
            } catch {
                if !Task.isCancelled { failure("音频导入失败：\(error.localizedDescription)") }
                await self?.stop(cancelFile: false)
            }
        }
    }

    func stop(cancelFile: Bool = true) async {
        if cancelFile { fileTask?.cancel(); fileTask = nil }
        if let engine { engine.stop(); engine.inputNode.removeTap(onBus: 0) }
        engine = nil
        if let systemStream { try? await systemStream.stopCapture() }
        systemStream = nil; systemOutput = nil
        await sink?.finish()
        if let analyzer {
            do { try await analyzer.finalizeAndFinishThroughEndOfInput() }
            catch { await analyzer.cancelAndFinishNow() }
        }
        if let resultsTask { await resultsTask.value }
        resultsTask = nil; sink = nil; analyzer = nil
    }
}
