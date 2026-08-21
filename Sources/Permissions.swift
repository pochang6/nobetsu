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

    /// イベントタップ用の許可判定は CoreGraphics 側の API を使う。
    /// IOHIDCheckAccess / IOHIDRequestAccess は HID デバイス向けで、用途が違う。
    static var inputMonitoringGranted: Bool {
        CGPreflightListenEventAccess()
    }

    /// 記録用。IOHID 側の見え方も併記しておくと切り分けが早い
    static var inputMonitoringStatusText: String {
        let cg = CGPreflightListenEventAccess() ? "granted" : "not granted"
        let hid: String
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: hid = "granted"
        case kIOHIDAccessTypeDenied:  hid = "denied"
        case kIOHIDAccessTypeUnknown: hid = "unknown"
        default:                      hid = "other"
        }
        return "CG=\(cg) HID=\(hid)"
    }

    /// 純正の許可ダイアログを出す。
    ///
    /// CGRequestListenEventAccess がイベントタップ用の正しい入口。
    ///
    /// 注意が2つある。
    /// 一つ目、**AXIsProcessTrusted() を先に呼ぶとこの要求が通らなくなる**という
    /// 既知の不具合がある。だからアクセシビリティには触れる前にこれを呼ぶ。
    /// 二つ目、アドホック署名のアプリは安定した Designated Requirement を持たないため、
    /// TCC がユーザーに尋ねることなく denied にする。署名の固定が前提条件になる。
    @discardableResult
    static func promptForInputMonitoring() -> Bool {
        if CGPreflightListenEventAccess() { return true }
        return CGRequestListenEventAccess()
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

    /// 記録用。アドホック署名かどうかが分かれば、TCC の即時 denied を切り分けられる
    static var signingSummary: String {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else {
            return "取得できず"
        }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(
            code as! SecStaticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &info) == errSecSuccess,
            let dict = info as? [String: Any]
        else {
            return "取得できず"
        }
        let identifier = dict["identifier"] as? String ?? "?"
        let flags = dict["flags"] as? UInt32 ?? 0
        let isAdhoc = (flags & 0x0000_0002) != 0  // kSecCodeSignatureAdhoc
        return "\(identifier) \(isAdhoc ? "adhoc(TCC に嫌われる)" : "安定した署名")"
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
