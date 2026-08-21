import SwiftUI
import AVFoundation
import Speech
import CoreMedia
import AppKit

// MARK: - 計測対象のエンジン

enum EngineKind: String, CaseIterable, Identifiable {
    case dictationLong
    case dictationLongFrequent
    case speechTranscriber

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dictationLong:         return "Dictation / progressiveLongDictation"
        case .dictationLongFrequent: return "Dictation / 上記 + frequentFinalization"
        case .speechTranscriber:     return "SpeechTranscriber / volatileResults"
        }
    }

    var note: String {
        switch self {
        case .dictationLong:         return "長時間口述の標準構成。句読点の自動挿入あり。"
        case .dictationLongFrequent: return "確定を頻繁に行い、確定待ちの遅延を詰める構成。"
        case .speechTranscriber:     return "高精度モデル側。句読点オプションは持たない。"
        }
    }
}

// MARK: - 計測値

struct Metrics {
    var startedAt: Date?
    var firstVolatileLatency: Double?   // 開始から最初の途中経過が出るまでの秒数
    var volatileUpdates = 0
    var finalChunks = 0
    var finalChars = 0
    var volatileLagSum = 0.0
    var volatileLagCount = 0
    var volatileLagMax = 0.0
    var finalLagSum = 0.0
    var finalLagCount = 0
    var finalLagMax = 0.0
    var peakLevel: Float = 0
    var silentTaps = 0
    var totalTaps = 0

    var avgVolatileLag: Double { volatileLagCount == 0 ? 0 : volatileLagSum / Double(volatileLagCount) }
    var avgFinalLag: Double { finalLagCount == 0 ? 0 : finalLagSum / Double(finalLagCount) }
}

/// オーディオスレッドから触るのでロックで保護する
final class AudioClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _seconds: Double = 0
    private var _level: Float = 0

    func advance(by seconds: Double, level: Float) {
        lock.lock(); _seconds += seconds; _level = level; lock.unlock()
    }
    var seconds: Double { lock.lock(); defer { lock.unlock() }; return _seconds }
    var level: Float { lock.lock(); defer { lock.unlock() }; return _level }
    func reset() { lock.lock(); _seconds = 0; _level = 0; lock.unlock() }
}

// MARK: - 本体

@MainActor
final class Recorder: ObservableObject {
    @Published var finalText = ""
    @Published var volatileText = ""
    @Published var status = "待機中"
    @Published var isRunning = false
    @Published var metrics = Metrics()
    @Published var level: Float = 0
    @Published var elapsed: Double = 0

    private let audioEngine = AVAudioEngine()
    private let clock = AudioClock()
    private var analyzer: SpeechAnalyzer?
    private var speechModule: SpeechTranscriber?
    private var dictationModule: DictationTranscriber?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var uiTimer: Timer?
    private var converter: AVAudioConverter?

    // MARK: 開始

    func start(kind: EngineKind) {
        guard !isRunning else { return }
        Task { await startAsync(kind: kind) }
    }

    private func startAsync(kind: EngineKind) async {
        reset()
        status = "マイク権限を確認中…"
        guard await requestMicrophone() else {
            status = "マイク権限が拒否されています（システム設定 > プライバシーとセキュリティ > マイク）"
            return
        }
        _ = await requestSpeechRecognition()

        let locale = Locale(identifier: "ja-JP")

        do {
            let modules: [any SpeechModule]
            switch kind {
            case .dictationLong:
                let m = DictationTranscriber(
                    locale: locale,
                    contentHints: [],
                    transcriptionOptions: [.punctuation],
                    reportingOptions: [.volatileResults],
                    attributeOptions: [.audioTimeRange])
                dictationModule = m
                modules = [m]
            case .dictationLongFrequent:
                let m = DictationTranscriber(
                    locale: locale,
                    contentHints: [],
                    transcriptionOptions: [.punctuation],
                    reportingOptions: [.volatileResults, .frequentFinalization],
                    attributeOptions: [.audioTimeRange])
                dictationModule = m
                modules = [m]
            case .speechTranscriber:
                guard SpeechTranscriber.isAvailable else {
                    status = "SpeechTranscriber がこの Mac では利用できません"
                    return
                }
                let m = SpeechTranscriber(
                    locale: locale,
                    transcriptionOptions: [],
                    reportingOptions: [.volatileResults],
                    attributeOptions: [.audioTimeRange])
                speechModule = m
                modules = [m]
            }

            try await prepareAssets(modules: modules, locale: locale)

            status = "音声フォーマットを解決中…"
            guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
                status = "対応する音声フォーマットが取得できませんでした"
                return
            }

            let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
            continuation = cont

            let a = SpeechAnalyzer(modules: modules)
            analyzer = a

            // 結果の購読を開始してから解析を走らせる
            if let m = dictationModule {
                resultsTask = consume(m) { String($0.text.characters) }
            } else if let m = speechModule {
                resultsTask = consume(m) { String($0.text.characters) }
            }

            try await a.start(inputSequence: stream)
            try startAudio(to: analyzerFormat)

            metrics.startedAt = Date()
            isRunning = true
            status = "認識中… (\(kind.label))"
            startUITimer()
        } catch {
            status = "開始に失敗: \(error.localizedDescription)"
            await stopAsync()
        }
    }

    // MARK: モデル資産

    private func prepareAssets(modules: [any SpeechModule], locale: Locale) async throws {
        let current = await AssetInventory.status(forModules: modules)
        switch current {
        case .unsupported:
            throw NSError(domain: "nobetsu", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "この構成では日本語 (ja-JP) が未対応です"])
        case .installed:
            status = "モデル導入済み"
        case .supported, .downloading:
            status = "モデルをダウンロード中… (初回のみ・数百MB)"
            if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                try await request.downloadAndInstall()
            }
            status = "モデル準備完了"
        @unknown default:
            break
        }
        _ = try? await AssetInventory.reserve(locale: locale)
    }

    // MARK: 結果の購読

    private func consume<M: SpeechModule>(
        _ module: M,
        text: @escaping @Sendable (M.Result) -> String
    ) -> Task<Void, Never> {
        Task { [weak self] in
            do {
                for try await result in module.results {
                    let s = text(result)
                    let isFinal = result.isFinal
                    let rangeEnd = result.range.end.seconds
                    await MainActor.run {
                        self?.handle(text: s, isFinal: isFinal, rangeEnd: rangeEnd)
                    }
                }
            } catch {
                await MainActor.run { self?.status = "認識ストリームが終了: \(error.localizedDescription)" }
            }
        }
    }

    private func handle(text: String, isFinal: Bool, rangeEnd: Double) {
        // 「今どこまで音声を渡したか」と「結果がどこまで到達したか」の差 = 実質的な体感遅延
        let lag = max(0, clock.seconds - rangeEnd)

        if isFinal {
            finalText += text
            volatileText = ""
            metrics.finalChunks += 1
            metrics.finalChars = finalText.count
            metrics.finalLagSum += lag
            metrics.finalLagCount += 1
            metrics.finalLagMax = max(metrics.finalLagMax, lag)
        } else {
            volatileText = text
            metrics.volatileUpdates += 1
            metrics.volatileLagSum += lag
            metrics.volatileLagCount += 1
            metrics.volatileLagMax = max(metrics.volatileLagMax, lag)
            if metrics.firstVolatileLatency == nil, let started = metrics.startedAt {
                metrics.firstVolatileLatency = Date().timeIntervalSince(started)
            }
        }
    }

    // MARK: オーディオ

    private func startAudio(to analyzerFormat: AVAudioFormat) throws {
        let input = audioEngine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw NSError(domain: "nobetsu", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "入力デバイスが見つかりません"])
        }
        guard let conv = AVAudioConverter(from: inputFormat, to: analyzerFormat) else {
            throw NSError(domain: "nobetsu", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "音声フォーマット変換を構成できません"])
        }
        converter = conv

        let cont = continuation
        let clock = self.clock

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            let seconds = Double(buffer.frameLength) / buffer.format.sampleRate
            let rms = Recorder.rms(of: buffer)
            clock.advance(by: seconds, level: rms)
            if let converted = Recorder.convert(buffer, to: analyzerFormat, using: conv) {
                cont?.yield(AnalyzerInput(buffer: converted))
            }
        }
        audioEngine.prepare()
        try audioEngine.start()
    }

    private nonisolated static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        let n = Int(buffer.frameLength)
        for i in 0..<n { let v = data[0][i]; sum += v * v }
        return (sum / Float(n)).squareRoot()
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

    // MARK: 停止

    func stop() {
        guard isRunning else { return }
        Task { await stopAsync() }
    }

    private func stopAsync() async {
        isRunning = false
        uiTimer?.invalidate(); uiTimer = nil

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
        speechModule = nil
        dictationModule = nil
        converter = nil

        if !volatileText.isEmpty {
            finalText += volatileText
            volatileText = ""
            metrics.finalChars = finalText.count
        }
        status = "停止しました"
    }

    private func reset() {
        finalText = ""
        volatileText = ""
        metrics = Metrics()
        elapsed = 0
        level = 0
        clock.reset()
    }

    private func startUITimer() {
        uiTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let started = self.metrics.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(started)
                self.level = self.clock.level
                self.metrics.peakLevel = max(self.metrics.peakLevel, self.clock.level)
            }
        }
    }

    // MARK: 権限

    private func requestMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    private func requestSpeechRecognition() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
    }

    // MARK: ログ

    func saveLog(kind: EngineKind) -> URL? {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nobetsu", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        let url = dir.appendingPathComponent("spike-\(fmt.string(from: Date())).md")

        let m = metrics
        let body = """
        # 音声入力 spike ログ

        - エンジン: \(kind.label)
        - 録音時間: \(String(format: "%.1f", elapsed)) 秒
        - 確定文字数: \(m.finalChars)
        - 確定チャンク数: \(m.finalChunks)
        - 途中経過の更新回数: \(m.volatileUpdates)
        - 最初の途中経過までの時間: \(m.firstVolatileLatency.map { String(format: "%.2f 秒", $0) } ?? "-")
        - 途中経過の遅延 平均/最大: \(String(format: "%.2f / %.2f 秒", m.avgVolatileLag, m.volatileLagMax))
        - 確定の遅延 平均/最大: \(String(format: "%.2f / %.2f 秒", m.avgFinalLag, m.finalLagMax))
        - 入力ピークレベル: \(String(format: "%.4f", m.peakLevel))

        ## 認識結果

        \(finalText)
        """
        try? body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

// MARK: - UI

struct ContentView: View {
    @StateObject private var rec = Recorder()
    @State private var kind: EngineKind = .dictationLongFrequent
    @State private var savedPath: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            transcript
            Divider()
            metricsView
        }
        .padding(16)
        .frame(minWidth: 760, minHeight: 560)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Picker("エンジン", selection: $kind) {
                    ForEach(EngineKind.allCases) { k in Text(k.label).tag(k) }
                }
                .frame(width: 420)
                .disabled(rec.isRunning)

                Button(rec.isRunning ? "停止" : "開始") {
                    rec.isRunning ? rec.stop() : rec.start(kind: kind)
                }
                .keyboardShortcut(.return, modifiers: .command)

                Button("コピー") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(rec.finalText + rec.volatileText, forType: .string)
                }
                .disabled(rec.finalText.isEmpty && rec.volatileText.isEmpty)

                Button("ログ保存") {
                    savedPath = rec.saveLog(kind: kind)?.path
                }
                .disabled(rec.finalText.isEmpty)
            }

            Text(kind.note).font(.caption).foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Circle()
                    .fill(rec.isRunning ? .red : .gray)
                    .frame(width: 9, height: 9)
                Text(rec.status).font(.callout)
                Spacer()
                Text(String(format: "%.1f 秒", rec.elapsed))
                    .font(.system(.callout, design: .monospaced))
            }

            // 集音レベル（弱すぎないかの確認用）
            ProgressView(value: Double(min(rec.level * 12, 1)))
                .progressViewStyle(.linear)
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                (Text(rec.finalText).foregroundStyle(.primary)
                 + Text(rec.volatileText).foregroundStyle(.secondary))
                    .font(.system(size: 15))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(8)
                    .id("body")
            }
            .frame(maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onChange(of: rec.finalText) { _, _ in proxy.scrollTo("body", anchor: .bottom) }
            .onChange(of: rec.volatileText) { _, _ in proxy.scrollTo("body", anchor: .bottom) }
        }
    }

    private var metricsView: some View {
        let m = rec.metrics
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 20) {
                stat("確定文字数", "\(m.finalChars)")
                stat("確定回数", "\(m.finalChunks)")
                stat("途中経過更新", "\(m.volatileUpdates)")
                stat("初回表示まで", m.firstVolatileLatency.map { String(format: "%.2fs", $0) } ?? "-")
            }
            HStack(spacing: 20) {
                stat("途中経過 遅延(平均)", String(format: "%.2fs", m.avgVolatileLag))
                stat("途中経過 遅延(最大)", String(format: "%.2fs", m.volatileLagMax))
                stat("確定 遅延(平均)", String(format: "%.2fs", m.avgFinalLag))
                stat("確定 遅延(最大)", String(format: "%.2fs", m.finalLagMax))
            }
            if let p = savedPath {
                Text("ログ: \(p)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(.body, design: .monospaced))
        }
    }
}

@main
struct NobetsuSpikeApp: App {
    var body: some Scene {
        WindowGroup("Nobetsu — 音声入力 spike") {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}
