import AppKit

/// 開始と終了を音で知らせる。
///
/// 画面を見ていなくても状態が分かることが大事。目を閉じて喋ることもあるし、
/// そもそも入力先のアプリを見ているので、こちらの表示は視界に入らない。
///
/// macOS 標準の音声入力の「ピポン」とは違う音を選ぶ。
/// 同じ音だと、どちらが動いているのか分からなくなる。
enum Sounds {

    /// 開始。高く短い音
    static func playStart() {
        play("Tink")
    }

    /// 終了。低く短い音。開始と対になるように選んである
    static func playStop() {
        play("Pop")
    }

    /// 何かに失敗したとき
    static func playFailure() {
        play("Basso")
    }

    private static func play(_ name: String) {
        guard enabled else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }

    /// 設定から切れるようにしておく。音が邪魔な場面もある
    static var enabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: key) == nil { return true }
            return UserDefaults.standard.bool(forKey: key)
        }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    private static let key = "nobetsu.soundEnabled"
}
