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
    /// マイクが本当に聞ける状態になった
    func dictationDidBeginCapturing()
}

/// macOS 26 の DictationTranscriber を使った日本語ストリーミング認識。
///
/// spike の計測結果（2026-08-21）に基づき DictationTranscriber を採用している。
/// SpeechTranscriber は初回表示まで 11.79 秒・確定遅延が平均 3.78 秒あり、
/// 喋りながら見るという用途には使えなかった。
@MainActor
final class DictationEngine {

    weak var delegate: DictationDelegate?
    private var lifecycle = DictationLifecycle()
    var isRunning: Bool { lifecycle.phase == .running }
    var isActive: Bool { lifecycle.isActive }
    var canStart: Bool { lifecycle.phase == .idle }
    private var startTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var audioConfigurationObserver: NSObjectProtocol?
    private var hasInputTap = false

    /// 入力レベル（0〜1 目安）。声が届いているかを目印に出すために使う
    var levelHandler: ((Float) -> Void)?

    /// 遠距離集音のヒント。spike では入力レベルが 0.027〜0.052 と低く、
    /// 本人も「60センチ離れている」と話していたため既定で有効にする。
    var useFarField = true

    /// 使うときだけ作って、終わったら捨てる。
    /// 停止しただけでは入力ノードがマイクを掴んだままになり、
    /// macOS 標準の音声入力が起動直後に切れる（マイクの奪い合いになる）。
    /// インスタンスごと解放することで、確実に手放す
    private var audioEngine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var transcriber: DictationTranscriber?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?

    private let locale = Locale(identifier: "ja-JP")

    /// マイクが動きはじめてから開始音を鳴らすまでの間。
    /// 無線イヤホンの接続切り替えをやり過ごすだけの長さがあればよい
    private static let startSoundSettle: TimeInterval = 0.25

    // MARK: - 開始

    func start() {
        guard let token = lifecycle.begin() else { return }
        notify(false, "マイクを確認中…（ESC で取り消し）")
        startTask = Task { await startAsync(token: token) }
    }

    private func checkCurrent(_ token: UInt64) throws {
        guard !Task.isCancelled, lifecycle.accepts(token) else { throw CancellationError() }
    }

    private func startAsync(token: UInt64) async {
        do {
            try checkCurrent(token)

            Log.write("mic: 現在の状態 = \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)")
            let microphoneOK = await requestMicrophone()
            try checkCurrent(token)
            guard microphoneOK else {
                stop(message: "マイクの権限がありません")
                return
            }
            let speechOK = await requestSpeechRecognition()
            try checkCurrent(token)
            Log.write("speech: 認可 = \(speechOK)")
            guard speechOK else {
                stop(message: "音声認識の権限がありません")
                return
            }

            var hints: Set<DictationTranscriber.ContentHint> = []
            if useFarField { hints.insert(.farField) }

            let module = DictationTranscriber(
                locale: locale,
                contentHints: hints,
                transcriptionOptions: [.punctuation],
                reportingOptions: [.volatileResults, .frequentFinalization],
                attributeOptions: [])
            transcriber = module

            try await prepareAssets(for: [module], token: token)
            try checkCurrent(token)

            let availableFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
            try checkCurrent(token)
            guard let format = availableFormat else {
                stop(message: "音声フォーマットを取得できませんでした")
                return
            }

            let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
            continuation = cont

            let a = SpeechAnalyzer(modules: [module])
            analyzer = a

            resultsTask = consume(module, token: token)

            try await a.start(inputSequence: stream)
            try checkCurrent(token)
            try startAudio(to: format, token: token)
            guard lifecycle.didStart(token) else { throw CancellationError() }
            notify(true, "認識中")

            // 開始音は「**本当に聞ける状態になってから**」鳴らす。
            //
            // 以前はマイクを起こす直前に鳴らしていた。無線イヤホンの接続切り替えに
            // 音が飲まれるのを避けるためだったが、**先頭の一文字が入らない**という
            // 別の問題を生んだ。音が鳴った瞬間に喋りはじめるのが自然なので、
            // その時点でまだ聞けていなければ、頭が削られる。
            //
            // 少し置くのは、無線イヤホンの切り替え（0.5秒ほど音が途切れる）を
            // やり過ごすため。マイクは既に動いているので、この間に喋っても取りこぼさない
            DispatchQueue.main.asyncAfter(deadline: .now() + DictationEngine.startSoundSettle) { [weak self] in
                guard let self, self.lifecycle.accepts(token), self.isRunning else { return }
                self.delegate?.dictationDidBeginCapturing()
            }
        } catch is CancellationError {
            // stop() が後始末を担当する。古い準備タスクから次の収録を触らない。
        } catch {
            guard lifecycle.accepts(token) else { return }
            stop(message: "開始できませんでした: \(error.localizedDescription)")
        }
    }

    private func prepareAssets(for modules: [any SpeechModule], token: UInt64) async throws {
        let status = await AssetInventory.status(forModules: modules)
        try checkCurrent(token)
        switch status {
        case .unsupported:
            throw NSError(domain: "nobetsu", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "日本語 (ja-JP) がこの構成では未対応です"])
        case .installed:
            break
        case .supported, .downloading:
            notify(false, "モデルを準備中…（初回のみ）")
            if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                try checkCurrent(token)
                try await request.downloadAndInstall()
                try checkCurrent(token)
            }
        @unknown default:
            break
        }
        try checkCurrent(token)
        _ = try? await AssetInventory.reserve(locale: locale)
    }

    // MARK: - 結果の購読

    private func consume(_ module: DictationTranscriber, token: UInt64) -> Task<Void, Never> {
        Task { [weak self] in
            do {
                for try await result in module.results {
                    guard let self, !Task.isCancelled, self.lifecycle.accepts(token) else { return }
                    let text = String(result.text.characters)
                    if result.isFinal {
                        self.delegate?.dictation(didFinalize: text)
                    } else {
                        self.delegate?.dictation(didUpdateVolatile: text)
                    }
                }
                guard let self, !Task.isCancelled, self.lifecycle.accepts(token) else { return }
                self.stop(message: "音声認識が終了しました")
            } catch {
                guard let self, !Task.isCancelled, self.lifecycle.accepts(token) else { return }
                self.stop(message: "認識が停止しました: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - オーディオ

    private func startAudio(to analyzerFormat: AVAudioFormat, token: UInt64) throws {
        let engine = AVAudioEngine()
        audioEngine = engine

        let input = engine.inputNode
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
        let onLevel = levelHandler
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            if let onLevel {
                let level = DictationEngine.rms(of: buffer)
                DispatchQueue.main.async { onLevel(level) }
            }
            if let converted = DictationEngine.convert(buffer, to: analyzerFormat, using: converter) {
                cont?.yield(AnalyzerInput(buffer: converted))
            }
        }
        hasInputTap = true
        engine.prepare()
        try engine.start()
        audioConfigurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.lifecycle.accepts(token) else { return }
                // 起動直後にも届く通知。これだけでは録音失敗と判断できない。
                // 実際の認識エラーは consume() で停止・解放する。
                Log.write("audio: 入出力構成の通知（エンジン稼働=\(self.audioEngine?.isRunning == true)）")
            }
        }

        Log.write("audio: マイクを取得した")
    }

    /// マイクを完全に手放す。
    /// tap を外す → 停止 → reset → インスタンスを捨てる、まで揃えないと、
    /// macOS 標準の音声入力が「起動してすぐ切れる」状態になる
    private func releaseAudio() {
        if let observer = audioConfigurationObserver {
            NotificationCenter.default.removeObserver(observer)
            audioConfigurationObserver = nil
        }
        guard let engine = audioEngine else { return }
        if hasInputTap { engine.inputNode.removeTap(onBus: 0) }
        hasInputTap = false
        engine.stop()
        engine.reset()
        audioEngine = nil
        Log.write("audio: マイクを解放した")
    }

    private nonisolated static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        let count = Int(buffer.frameLength)
        for i in 0..<count {
            let v = data[0][i]
            sum += v * v
        }
        return (sum / Float(count)).squareRoot()
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

    /// 区間をここで区切る。
    /// 送信などで文脈が切れたとき、次の文を新しい区間として始めるために使う
    func cutSpan() {
        guard isRunning, let analyzer else { return }
        Log.write("engine: 区間を区切る")
        Task { try? await analyzer.finalize(through: nil) }
    }

    // MARK: - 停止

    func stop(message: String = "待機中") {
        guard let token = lifecycle.stop() else { return }
        let preparation = startTask
        startTask = nil
        preparation?.cancel()
        // await より前にマイクと共有リソースを解放する。
        releaseAudio()
        continuation?.finish()
        continuation = nil
        resultsTask?.cancel()
        resultsTask = nil
        let oldAnalyzer = analyzer
        analyzer = nil
        transcriber = nil
        notify(false, message == "待機中" ? "停止処理中…" : message)
        stopTask = Task {
            await oldAnalyzer?.cancelAndFinishNow()
            await preparation?.value
            lifecycle.didStop(token)
            stopTask = nil
            notify(false, message)
        }
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
        Log.write("engine: running=\(running) \(message)")
        delegate?.dictation(didChangeRunning: running, message: message)
    }
}
