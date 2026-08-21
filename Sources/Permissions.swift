import Foundation
import AppKit
import ApplicationServices
import IOKit.hid

/// 権限まわりの判定をここに集める。
///
/// キー入力を見張るには、macOS では2つの許可が絡む。
/// - アクセシビリティ … イベントを書き換えたり飲み込んだりする権限
/// - 入力監視 … キー入力を受け取る権限
/// どちらが要るかは タップの種類や OS の版で変わるので、両方を面倒見る。
///
/// もう一つ厄介なのが AXIsProcessTrusted() の挙動で、
/// 起動中のプロセスでは結果がキャッシュされ、許可しても false のままになることがある。
/// そのため「許可されたか」の最終判定は、実際にイベントタップを作れるかどうかで行う。
enum Permissions {

    // MARK: - アクセシビリティ

    static var accessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    /// 一覧に載せずに登録だけする（起動直後に呼ぶ用）
    @discardableResult
    static func registerForAccessibility() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString
        return AXIsProcessTrustedWithOptions([key: false] as CFDictionary)
    }

    /// 純正の許可ダイアログを出す。
    ///
    /// これを避けて自前の案内だけで済ませようとすると、かえって遠回りになる。
    /// 純正ダイアログの「システム設定を開く」を押すと、**一覧にこのアプリが載った状態で**
    /// 設定画面が開く。＋ を押して Finder からアプリを探す手間が丸ごと消える。
    /// 二重ダイアログを避けたいなら、出さないのではなく、こちらの窓を引っ込めればよい。
    @discardableResult
    static func promptForAccessibility() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    // MARK: - 入力監視

    static var inputMonitoringGranted: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    /// 純正の許可ダイアログを出す。
    ///
    /// アクセシビリティ側と同じく、これが一覧への登録と設定画面への近道を兼ねる。
    /// さらに許可したあとは macOS 自身が「終了して再度開く」を提案してくれるので、
    /// 再起動の面倒まで OS が引き受けてくれる。自前で用意するより確実で分かりやすい。
    @discardableResult
    static func promptForInputMonitoring() -> Bool {
        if inputMonitoringGranted { return true }
        return IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    // MARK: - 実力判定

    /// 実際にイベントタップを作れるか試す。作れたらすぐ畳む。
    /// AXIsProcessTrusted() のキャッシュに惑わされない、唯一あてになる判定
    static func canCreateEventTap() -> Bool {
        let mask: CGEventMask = 1 << CGEventType.flagsChanged.rawValue
        guard let probe = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
            userInfo: nil)
        else {
            return false
        }
        CGEvent.tapEnable(tap: probe, enable: false)
        return true
    }

    // MARK: - 設定画面

    static func openAccessibilitySettings() {
        open([
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
        ])
    }

    static func openInputMonitoringSettings() {
        open([
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ListenEvent",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent",
        ])
    }

    private static func open(_ candidates: [String]) {
        for string in candidates {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
    }

    // MARK: - 入れ替え

    /// 自分を起動し直して、古いプロセスを畳む。
    /// 権限の判定はプロセス起動時に固まるため、確実に反映させるにはこれが要る
    static func relaunch() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
