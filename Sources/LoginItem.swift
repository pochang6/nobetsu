import Foundation
import ServiceManagement

/// ログイン時の自動起動。
///
/// 常駐して待ち受けるアプリなので、毎回自分で起動するようでは意味がない。
/// 既定で有効にするが、初回に一度きり設定するだけで、以後はユーザーの選択を尊重する。
enum LoginItem {

    private static let didInitializeKey = "nobetsu.loginItemInitialized"

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// 初回起動時に一度だけ既定で有効にする。
    /// 毎回勝手に有効化すると、切ったつもりが戻る、という不快な挙動になる
    static func applyDefaultOnFirstLaunch() {
        guard !UserDefaults.standard.bool(forKey: didInitializeKey) else { return }
        UserDefaults.standard.set(true, forKey: didInitializeKey)
        setEnabled(true)
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
            Log.write("login item: \(enabled ? "有効" : "無効") にした")
        } catch {
            Log.write("login item: 変更に失敗 \(error.localizedDescription)")
        }
    }
}
