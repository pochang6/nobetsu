import Foundation
import AppKit
import CoreGraphics

/// キーの見張り番。
///
/// - ⌘ を単独で長押し → 開始
/// - もう一度 ⌘ を単独で軽く叩く → 停止
/// - ESC → 停止（認識中だけ横取りするので、普段の ESC は素通しする）
///
/// ⌘ は macOS のあらゆるショートカットの起点なので、素朴に「長押しで発火」にすると
/// ⌘Tab や ⌘S を打とうとして一瞬ためらっただけで暴発する。
/// そこで **押している間に他のキーやクリックが来たら、それはショートカットだと見なして取り下げる**。
///
/// CGEventTap を使うのは、認識中の ESC を「横取りして飲み込む」必要があるため。
/// Carbon の RegisterEventHotKey ではイベントを消せない。
@MainActor
final class TriggerMonitor {

    /// 自分が打ち込んだイベントに付ける印。これを見て自分のイベントを無視する
    nonisolated static let injectedMagic: Int64 = 0x4E_42_54_53  // 'NBTS'

    /// 長押しと判定するまでの時間
    var holdThreshold: TimeInterval = 0.5

    /// 右⌘ だけを開始キーにする。既定は左右どちらでも反応する
    var rightCommandOnly = false

    var onStart: (() -> Void)?
    var onStop: (() -> Void)?
    /// 認識中に利用者が自分で入力した（キー入力・クリックなど）
    var onUserTookOver: (() -> Void)?
    /// 認識中に Enter で送信した。文脈の切れ目として扱う
    var onUserSubmitted: (() -> Void)?
    var isRunning = false

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private var commandDownAt: Date?
    private var commandKeyCode: Int64 = 0
    /// この押下は他のキーと組み合わされた（＝ショートカットだった）
    private var holdInvalidated = false
    /// この押下で既に開始した。離しても停止させないための印
    private var holdConsumed = false
    private var holdTimer: Timer?

    private static let keyEscape: Int64 = 53
    private static let keyCommandLeft: Int64 = 55
    private static let keyCommandRight: Int64 = 54
    private static let keyReturn: Int64 = 36
    private static let keyEnter: Int64 = 76

    /// 預かった Enter を流すまでの待ち時間。
    /// 打ち込みが着くには十分で、押した本人には気づかれない程度
    private static let returnHoldDelay: TimeInterval = 0.12

    nonisolated(unsafe) private static weak var current: TriggerMonitor?

    // MARK: - 起動

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        TriggerMonitor.current = self

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue)

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, _ in
                TriggerMonitor.dispatch(type: type, event: event)
            },
            userInfo: nil)
        else {
            return false
        }

        tap = port
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    func stopMonitoring() {
        holdTimer?.invalidate()
        holdTimer = nil
        if let port = tap { CGEvent.tapEnable(tap: port, enable: false) }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        runLoopSource = nil
        tap = nil
    }

    // MARK: - イベントの入口（C 関数ポインタからは値を掴めないので静的に受ける）

    nonisolated private static func dispatch(
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {

        // タップが重い処理で無効化されたら戻す。
        // コールバックの中で時間を使うと macOS がタップを切るので、
        // ここに来るということは、どこかで待たせている
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Log.write("⚠️ イベントタップが無効化された (\(type == .tapDisabledByTimeout ? "timeout" : "userInput")) → 再有効化する")
            if let monitor = current, let port = MainActor.assumeIsolated({ monitor.tap }) {
                CGEvent.tapEnable(tap: port, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        // 自分が打ち込んだ文字は見張りの対象外
        if event.getIntegerValueField(.eventSourceUserData) == injectedMagic {
            return Unmanaged.passUnretained(event)
        }

        guard let monitor = current else { return Unmanaged.passUnretained(event) }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        let swallow = MainActor.assumeIsolated {
            monitor.handle(type: type, keyCode: keyCode, flags: flags)
        }
        return swallow ? nil : Unmanaged.passUnretained(event)
    }

    /// 戻り値 true でイベントを飲み込む
    private func handle(type: CGEventType, keyCode: Int64, flags: CGEventFlags) -> Bool {

        switch type {

        case .flagsChanged:
            let isCommandKey = (keyCode == TriggerMonitor.keyCommandLeft
                                || keyCode == TriggerMonitor.keyCommandRight)
            guard isCommandKey else {
                // ⌘ 以外の修飾キーが動いた。⌘ と組み合わせているならショートカット
                if commandDownAt != nil { holdInvalidated = true }
                return false
            }

            if flags.contains(.maskCommand) {
                commandDown(keyCode: keyCode)
            } else {
                commandUp()
            }
            return false

        case .keyDown:
            // 認識中の ESC は飲み込んで停止に使う。
            // 呼び出しはコールバックの外へ逃がす。ここで待たせるとタップが切られる
            if isRunning && keyCode == TriggerMonitor.keyEscape {
                Log.write("ESC → 停止")
                // 打ち込みは**この場で**止める。停止処理を待つと、
                // その隙間に溜まっていた文字が流れ込み、止めたあとに句点だけが現れる
                fireUserTookOver()
                fireStop()
                return true
            }
            // 認識中に利用者が自分でキーを打った。Enter で送信した場合も含む。
            // こちらの「打ち込み済みの末尾」が当てにならなくなるので知らせる
            if isRunning {
                fireUserTookOver()

                // Enter だけは特別扱いする。
                //
                // 文字は CGEvent で投げているので、投げてからアプリが処理するまでに間がある。
                // 送信の直前に投げた1〜2文字が Enter より後に着くと、
                // 送信し終えて空になった入力欄に、その文字だけが取り残される。
                // 実際に「。」だけが残る形で再現した。
                //
                // そこで Enter を一瞬だけ預かり、こちらの文字が着くのを待ってから流す。
                if keyCode == TriggerMonitor.keyReturn || keyCode == TriggerMonitor.keyEnter {
                    onUserSubmitted?()
                    holdAndReplayReturn(keyCode: keyCode, flags: flags)
                    return true
                }
            }

            // ⌘ を押している最中に他のキーが来た＝ショートカット。長押し判定を取り下げる
            if commandDownAt != nil { invalidateHold() }
            return false

        case .leftMouseDown, .rightMouseDown:
            // クリックでカーソルが動いた可能性がある。こちらも基準を失う
            if isRunning { fireUserTookOver() }
            if commandDownAt != nil { invalidateHold() }
            return false

        default:
            return false
        }
    }

    // MARK: - ⌘ の押し下げと離し

    private func commandDown(keyCode: Int64) {
        guard commandDownAt == nil else { return }

        commandDownAt = Date()
        commandKeyCode = keyCode
        holdInvalidated = false
        holdConsumed = false

        guard !isRunning else { return }

        if rightCommandOnly && keyCode != TriggerMonitor.keyCommandRight { return }

        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: holdThreshold, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.holdTimer = nil
                guard self.commandDownAt != nil, !self.holdInvalidated, !self.isRunning else { return }
                self.holdConsumed = true
                Log.write("⌘ 長押しを検知 → 開始")
                self.fireStart()
            }
        }
    }

    private func commandUp() {
        let heldSince = commandDownAt
        let wasInvalidated = holdInvalidated
        let didStart = holdConsumed

        holdTimer?.invalidate()
        holdTimer = nil
        commandDownAt = nil
        holdInvalidated = false
        holdConsumed = false

        guard let heldSince else { return }

        // 長押しで開始した直後の「離す」で止めてしまわない
        if didStart { return }

        // 認識中に ⌘ を単独で軽く叩いたら停止。
        // ⌘V などショートカットの一部だった場合は無効化されているので止まらない
        let held = Date().timeIntervalSince(heldSince)
        if isRunning && !wasInvalidated && held < holdThreshold {
            Log.write("⌘ の単独タップ → 停止")
            // ESC と同じ理由で、打ち込みはこの場で止める
            fireUserTookOver()
            fireStop()
        }
    }

    /// イベントタップのコールバックを塞がないよう、必ず次のループへ逃がす。
    /// ここで OS のダイアログを出したり音声エンジンを起こしたりすると、
    /// macOS がタップを無効化して、以後キーが一切効かなくなる
    private func fireStart() {
        DispatchQueue.main.async { [weak self] in self?.onStart?() }
    }

    private func fireStop() {
        DispatchQueue.main.async { [weak self] in self?.onStop?() }
    }

    /// これだけは**同期で**呼ぶ。
    ///
    /// イベントタップのコールバックは、キーがアプリへ届く「前」に呼ばれる。
    /// ここで打ち込みを止めておかないと、Enter で送信された直後に
    /// 積んであった1〜2文字が空になった入力欄へ流れ込んでしまう。
    /// 中身は配列の退避とタイマーの停止だけなので、コールバックを塞ぐ心配はない。
    private func fireUserTookOver() {
        onUserTookOver?()
    }

    /// Enter を飲み込んで、少し置いてから同じものを流し直す。
    /// 修飾キーはそのまま引き継ぐ（⌘Enter や Shift+Enter を壊さないため）。
    /// 流し直す側には自分の印を付けて、再びここへ戻ってこないようにする。
    private func holdAndReplayReturn(keyCode: Int64, flags: CGEventFlags) {
        DispatchQueue.main.asyncAfter(deadline: .now() + TriggerMonitor.returnHoldDelay) {
            guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
            for isDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source,
                                          virtualKey: CGKeyCode(keyCode),
                                          keyDown: isDown) else { continue }
                event.flags = flags
                event.setIntegerValueField(.eventSourceUserData,
                                           value: TriggerMonitor.injectedMagic)
                event.post(tap: .cgAnnotatedSessionEventTap)
            }
        }
    }

    private func invalidateHold() {
        holdInvalidated = true
        holdTimer?.invalidate()
        holdTimer = nil
    }

    deinit {
        if let port = tap { CGEvent.tapEnable(tap: port, enable: false) }
    }
}
