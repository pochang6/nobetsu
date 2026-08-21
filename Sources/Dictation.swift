import Foundation
import AVFoundation
import Speech

/// 認識結果の受け取り先
@MainActor
protocol DictationDelegate: AnyObject {
    /// 未確定テキストが更新された（この区間の全文が毎回渡される）
    func dictation(didUpdateVolatile text: String)
    /// 区間が確定した（この区間の確定全文が渡される）
    func dictation(didFinalize text: String)
    /// 稼働状態が変わった
    func dictation(didChangeRunning running: Bool, message: String)
}

/// macOS 26 の DictationTranscriber を使った日本語ストリーミング認識。
///
/// spike の計測結果（2026-08-21）に基づき DictationTranscriber を採用している。
/// SpeechTranscriber は初回表示まで 11.79 秒・確定遅延が平均 3.78 秒あり、
/// 喋りながら見るという用途には使えなかった。
@MainActor
final class DictationEngine {

    weak var delegate: DictationDelegate?
    private(set) var isRunning = false

    /// 遠距離集音のヒント。spike では入力レベルが 0.027〜0.052 と低く、
    /// 本人も「60センチ離れている」と話していたため既定で有効にする。
    var useFarField = true

    private let audioEngine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var transcriber: DictationTranscriber?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?

    private let locale = Locale(identifier: "ja-JP")

    // MARK: - 開始

    func start() {
        guard !isRunning else { return }
        Task { await startAsync() }
    }

    private func startAsync() async {
        notify(false, "マイクを確認中…")

        guard await requestMicrophone() else {
            notify(false, "マイクの権限がありません")
            return
        }
        _ = await requestSpeechRecognition()

        var hints: Set<DictationTranscriber.ContentHint> = []
        if useFarField { hints.insert(.farField) }

        let module = DictationTranscriber(
            locale: locale,
            contentHints: hints,
            transcriptionOptions: [.punctuation],
            reportingOptions: [.volatileResults, .frequentFinalization],
            attributeOptions: [])
        transcriber = module

        do {
            try await prepareAssets(for: [module])

            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
                notify(false, "音声フォーマットを取得できませんでした")
                return
            }

            let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
            continuation = cont

            let a = SpeechAnalyzer(modules: [module])
            analyzer = a

            resultsTask = consume(module)

            try await a.start(inputSequence: stream)
            try startAudio(to: format)

            isRunning = true
            notify(true, "認識中")
        } catch {
            notify(false, "開始できませんでした: \(error.localizedDescription)")
            await stopAsync()
        }
    }

    private func prepareAssets(for modules: [any SpeechModule]) async throws {
        switch await AssetInventory.status(forModules: modules) {
        case .unsupported:
            throw NSError(domain: "nobetsu", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "日本語 (ja-JP) がこの構成では未対応です"])
        case .installed:
            break
        case .supported, .downloading:
            notify(false, "モデルを準備中…（初回のみ）")
            if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                try await request.downloadAndInstall()
            }
        @unknown default:
            break
        }
        _ = try? await AssetInventory.reserve(locale: locale)
    }

    // MARK: - 結果の購読

    private func consume(_ module: DictationTranscriber) -> Task<Void, Never> {
        Task { [weak self] in
            do {
                for try await result in module.results {
                    let text = String(result.text.characters)
                    let isFinal = result.isFinal
                    await MainActor.run {
                        guard let self else { return }
                        if isFinal {
                            self.delegate?.dictation(didFinalize: text)
                        } else {
                            self.delegate?.dictation(didUpdateVolatile: text)
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self?.notify(false, "認識が停止しました: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - オーディオ

    private func startAudio(to analyzerFormat: AVAudioFormat) throws {
        let input = audioEngine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0 else {
            throw NSError(domain: "nobetsu", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "入力デバイスが見つかりません"])
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: analyzerFormat) else {
            throw NSError(domain: "nobetsu", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "音声フォーマットを変換できません"])
        }

        let cont = continuation
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            if let converted = DictationEngine.convert(buffer, to: analyzerFormat, using: converter) {
                cont?.yield(AnalyzerInput(buffer: converted))
            }
        }
        audioEngine.prepare()
        try audioEngine.start()
    }

    private nonisolated static func convert(
        _ buffer: AVAudioPCMBuffer,
        to format: AVAudioFormat,
        using converter: AVAudioConverter
    ) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        var error: NSError?
        var delivered = false
        let outcome = converter.convert(to: out, error: &error) { _, statusPtr in
            if delivered {
                statusPtr.pointee = .noDataNow
                return nil
            }
            delivered = true
            statusPtr.pointee = .haveData
            return buffer
        }
        if outcome == .error || out.frameLength == 0 { return nil }
        return out
    }

    // MARK: - 停止

    func stop() {
        guard isRunning else { return }
        Task { await stopAsync() }
    }

    private func stopAsync() async {
        isRunning = false

        if audioEngine.isRunning {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }
        continuation?.finish()
        continuation = nil

        if let a = analyzer {
            try? await a.finalizeAndFinishThroughEndOfInput()
        }
        resultsTask?.cancel()
        resultsTask = nil
        analyzer = nil
        transcriber = nil

        notify(false, "待機中")
    }

    // MARK: - 権限

    private func requestMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    private func requestSpeechRecognition() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
    }

    private func notify(_ running: Bool, _ message: String) {
        delegate?.dictation(didChangeRunning: running, message: message)
    }
}
