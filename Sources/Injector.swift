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

    var isTrusted: Bool { AXIsProcessTrusted() }

    // MARK: - 外部から呼ぶ入口

    /// 未確定テキストの更新。頻度制限をかけて適用する
    func updateVolatile(_ text: String) {
        queued = text
        scheduleFlush()
    }

    /// 区間の確定。頻度制限を無視して即座に適用し、その区間を締める
    func finalize(_ text: String) {
        flushTimer?.invalidate()
        flushTimer = nil
        queued = nil
        apply(text)
        // 確定した分はもう打ち直さない。次の区間は白紙から始まる
        pending = []
    }

    /// 中断。打ち込み済みの未確定分はそのまま残す（消すと入力が失われるため）
    func reset() {
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

    // MARK: - 権限

    /// アクセシビリティ権限を要求する。CGEvent の送出にはこれが必須
    @discardableResult
    func requestAccessibilityIfNeeded() -> Bool {
        if AXIsProcessTrusted() { return true }
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}
