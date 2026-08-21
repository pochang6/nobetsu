import Foundation
import AppKit
import ApplicationServices

/// 最前面のアプリへ、日本語入力（IME）を経由せずに直接文字を打ち込む。
///
/// これが nobetsu の核心。macOS 標準の音声入力は認識した「よみ」を IME に流し込むため、
/// ライブ変換が未確定文節を書き換え続けるのと衝突して固まる。
/// DictationTranscriber は漢字かな交じりの確定済みテキストを返すので、
/// CGEvent の Unicode 直接入力を使えば IME を完全に迂回できる。変換が介在しないので衝突しない。
///
/// 途中経過は「楽観的に挿入して、変わった部分だけ打ち直す」方式で反映する。
/// 確定を待つと spike の計測どおり 20 秒以上グレーのまま放置されるため、実用にならない。
@MainActor
final class TextInjector {

    /// 直近に打ち込んだ未確定テキスト。確定するたびに空へ戻す
    private var pending: [Character] = []

    /// 打ち直しの頻度制限。途中経過は毎秒5回ほど飛んでくるので、そのまま流すと打鍵が渋滞する
    private var lastApplied = Date.distantPast
    private let minInterval: TimeInterval = 0.25
    private var queued: String?
    private var flushTimer: Timer?

    /// 打鍵中に立てるフラグ。自分が出したイベントで再入するのを防ぐ
    private(set) var isInjecting = false

    /// 打ち込んだ直後に呼ばれる。
    /// macOS はキー入力のたびにマウスカーソルを隠すので、
    /// 隠された直後に出し直したい相手へ知らせる
    var didInject: (() -> Void)?

    /// 収録中かどうか。停止後に遅れて届く結果を打ち込まないための門
    private var accepting = false

    /// 利用者が自分でキーを打つなどして、こちらの打ち込み済み位置が当てにならなくなった
    private var baselineLost = false

    /// 送信などで文脈が切れた。今の区間はもう打ち込まない
    private var discardCurrentSpan = false

    /// 基準を失う直前まで打ち込んでいた内容。
    /// 認識は続いているので、次に届く未確定テキストはこれで始まるはず。
    /// そのときは「続きだけ」を打てば、消さずに、重複もせずに復帰できる
    private var abandonedPrefix: [Character] = []

    var isTrusted: Bool { AXIsProcessTrusted() }

    // MARK: - 収録の開始と終了

    func beginSession() {
        accepting = true
        baselineLost = false
        discardCurrentSpan = false
        abandonedPrefix = []
        clearPending()
    }

    /// 収録の終了。**ここから先に届く結果は一切打ち込まない。**
    ///
    /// 停止すると、認識器は最後の区間の確定結果を遅れて返してくる。
    /// それをそのまま適用すると、打ち込み済みの位置情報を失った状態で
    /// 同じ文章をもう一度打ってしまい、二重入力になる。
    /// 画面にはもう未確定分が出ているので、そのまま残すのが正しい。
    func endSession() {
        accepting = false
        baselineLost = false
        discardCurrentSpan = false
        abandonedPrefix = []
        clearPending()
    }

    // MARK: - 外部から呼ぶ入口

    /// 送信された。この文章はここで終わりなので、今の区間の続きは追いかけない。
    ///
    /// 「利用者が操作した」扱いにして復帰させると、送信して空になった入力欄へ
    /// 末尾の句点だけが遅れて届く。実際にそれが起きた。
    /// 送信は文脈の切れ目なので、次の区間から新しく始めるのが正しい。
    func userSubmitted() {
        guard accepting else { return }
        clearPending()
        abandonedPrefix = []
        baselineLost = false
        discardCurrentSpan = true
    }

    /// 未確定テキストの更新。頻度制限をかけて適用する
    func updateVolatile(_ text: String) {
        guard accepting, !discardCurrentSpan else { return }
        if baselineLost, !tryRecover(with: text) { return }
        queued = text
        scheduleFlush()
    }

    /// 基準を失った状態から復帰できるか試す。
    ///
    /// 認識そのものは止まっていないので、次に届く未確定テキストは
    /// 直前まで打ち込んでいた内容で始まる。始まっていれば、
    /// その続きだけを打てばよい。消す必要も、打ち直す必要もない。
    ///
    /// 始まっていない（言い直した、認識が変わった）場合は、この区間は諦めて
    /// 次の確定を待つ。中途半端に打つと文章が壊れる
    private func tryRecover(with text: String) -> Bool {
        let next = Array(text)
        guard next.count >= abandonedPrefix.count,
              Array(next[0..<abandonedPrefix.count]) == abandonedPrefix
        else {
            return false
        }
        pending = abandonedPrefix
        abandonedPrefix = []
        baselineLost = false
        return true
    }

    /// 区間の確定。頻度制限を無視して即座に適用し、その区間を締める
    func finalize(_ text: String) {
        guard accepting else { return }

        flushTimer?.invalidate()
        flushTimer = nil
        queued = nil

        // 送信で切れた区間はここで締める。中身は打たない
        if discardCurrentSpan {
            discardCurrentSpan = false
            pending = []
            return
        }

        // 基準を失っている場合も、続きとして繋がるなら打つ。
        // 繋がらないなら、打ち込み済みの文章は利用者の手元にあるので何もしない
        if baselineLost, !tryRecover(with: text) {
            baselineLost = false
            abandonedPrefix = []
            pending = []
            return
        }

        apply(text)
        // 確定した分はもう打ち直さない。次の区間は白紙から始まる
        pending = []
    }

    /// 利用者が自分でキーを打った、クリックした、送信した。
    ///
    /// こちらが把握している「打ち込み済みの末尾」はもう当てにならない。
    /// この状態で差分を適用すると、Backspace が利用者の文章を削りにいく。
    /// チャット欄で喋りながら Enter を押す、という操作は実際によく起きる。
    func userTookOver() {
        guard accepting, !baselineLost else { return }
        // 何を打ち込んであったかは覚えておく。次の未確定テキストと突き合わせて復帰する
        abandonedPrefix = pending
        clearPending()
        baselineLost = true
    }

    /// 中断。打ち込み済みの未確定分はそのまま残す（消すと入力が失われるため）
    func reset() {
        clearPending()
    }

    private func clearPending() {
        flushTimer?.invalidate()
        flushTimer = nil
        queued = nil
        pending = []
    }

    // MARK: - 適用

    private func scheduleFlush() {
        let elapsed = Date().timeIntervalSince(lastApplied)
        if elapsed >= minInterval {
            flushNow()
            return
        }
        guard flushTimer == nil else { return }
        flushTimer = Timer.scheduledTimer(withTimeInterval: minInterval - elapsed, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.flushTimer = nil
                self?.flushNow()
            }
        }
    }

    private func flushNow() {
        guard let text = queued else { return }
        queued = nil
        apply(text)
    }

    /// 現在打ち込み済みの未確定テキストを `text` の状態へ持っていく。
    /// 共通接頭辞は据え置き、食い違った末尾だけを削除して打ち直す。
    private func apply(_ text: String) {
        let next = Array(text)
        let common = commonPrefixLength(pending, next)

        let deleteCount = pending.count - common
        let insert = String(next[common...])

        guard deleteCount > 0 || !insert.isEmpty else { return }

        isInjecting = true
        defer {
            isInjecting = false
            lastApplied = Date()
            pending = next
            // 今の打鍵で macOS がカーソルを隠した。隠れたままにさせない
            didInject?()
        }

        if deleteCount > 0 { sendBackspaces(deleteCount) }
        if !insert.isEmpty { sendText(insert) }
    }

    private func commonPrefixLength(_ a: [Character], _ b: [Character]) -> Int {
        var i = 0
        let n = min(a.count, b.count)
        while i < n, a[i] == b[i] { i += 1 }
        return i
    }

    // MARK: - CGEvent

    /// Unicode 文字列をそのままキーイベントとして送る。
    /// virtualKey を 0 にして keyboardSetUnicodeString を使うのが要点で、
    /// これならキーボードレイアウトにも IME にも依存せず文字が入る。
    private func sendText(_ text: String) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }

        // 1イベントに詰め込みすぎると取りこぼすアプリがあるので分割する
        let units = Array(text.utf16)
        let chunkSize = 16
        var index = 0

        while index < units.count {
            let end = min(index + chunkSize, units.count)
            var chunk = Array(units[index..<end])

            if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                down.setIntegerValueField(.eventSourceUserData, value: TriggerMonitor.injectedMagic)
                down.post(tap: .cgAnnotatedSessionEventTap)
            }
            if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                up.setIntegerValueField(.eventSourceUserData, value: TriggerMonitor.injectedMagic)
                up.post(tap: .cgAnnotatedSessionEventTap)
            }
            index = end
        }
    }

    private func sendBackspaces(_ count: Int) {
        guard count > 0, let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let deleteKey: CGKeyCode = 51  // Delete (Backspace)

        for _ in 0..<count {
            if let down = CGEvent(keyboardEventSource: source, virtualKey: deleteKey, keyDown: true) {
                down.setIntegerValueField(.eventSourceUserData, value: TriggerMonitor.injectedMagic)
                down.post(tap: .cgAnnotatedSessionEventTap)
            }
            if let up = CGEvent(keyboardEventSource: source, virtualKey: deleteKey, keyDown: false) {
                up.setIntegerValueField(.eventSourceUserData, value: TriggerMonitor.injectedMagic)
                up.post(tap: .cgAnnotatedSessionEventTap)
            }
        }
    }

}
