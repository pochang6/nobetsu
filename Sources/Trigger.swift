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

        // タップが重い処理で無効化されたら戻す
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
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
            // 認識中の ESC は飲み込んで停止に使う
            if isRunning && keyCode == TriggerMonitor.keyEscape {
                onStop?()
                return true
            }
            // ⌘ を押している最中に他のキーが来た＝ショートカット。長押し判定を取り下げる
            if commandDownAt != nil { invalidateHold() }
            return false

        case .leftMouseDown, .rightMouseDown:
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
                self.onStart?()
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
            onStop?()
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
