import Foundation
import AudioToolbox

/// 開始と終了を音で知らせる。
///
/// 画面を見ていなくても状態が分かることが大事。目を閉じて喋ることもあるし、
/// そもそも入力先のアプリを見ているので、こちらの表示は視界に入らない。
///
/// タイミングが肝になる。
/// **開始音は「本当に音声を受け付けられるようになった瞬間」に鳴らす。**
/// 早すぎると、まだ聞いていないのに喋り出してしまい、頭が欠ける。
/// **終了音は「止める操作をした瞬間」に鳴らす。**
/// 後始末が終わってから鳴らすと、止めたのに反応が無い時間が生まれる。
///
/// 実装には AudioToolbox を使う。NSSound は再生中の状態管理が絡み、
/// 使い回すと鳴らなくなることがあった。こちらは鳴らしっぱなしで投げるだけなので確実。
///
/// macOS 標準の音声入力の「ピポン」とは違う音を選ぶ。
/// 同じ音だと、どちらが動いているのか分からなくなる。
enum Sounds {

    /// 開始。音声を受け付けられるようになった合図
    static func playStart() { play(startID, "開始音") }

    /// 終了
    static func playStop() { play(stopID, "終了音") }

    /// 自分から止めたのではなく、入力先から離れたので止まった。
    /// **終了音と同じにしてはいけない。** 押していないのに終わったとき、
    /// 何が起きたのか分からないまま音だけ鳴ると、驚くだけで手掛かりにならない
    static func playAutoStop() { play(autoStopID, "自動停止音") }

    /// 何かに失敗したとき
    static func playFailure() { play(failureID, "失敗音") }

    // MARK: - 音の登録

    private static let startID = register("Glass")
    private static let stopID = register("Pop")
    private static let autoStopID = register("Submarine")
    private static let failureID = register("Basso")

    private static func register(_ name: String) -> SystemSoundID? {
        let url = URL(fileURLWithPath: "/System/Library/Sounds/\(name).aiff")
        guard FileManager.default.fileExists(atPath: url.path) else {
            Log.write("sound: \(name).aiff が見つかりません")
            return nil
        }
        var id: SystemSoundID = 0
        let status = AudioServicesCreateSystemSoundID(url as CFURL, &id)
        guard status == kAudioServicesNoError else {
            Log.write("sound: \(name) を登録できません (status=\(status))")
            return nil
        }
        return id
    }

    private static func play(_ id: SystemSoundID?, _ label: String = #function) {
        guard enabled else {
            Log.write("sound: \(label) は設定で切られている")
            return
        }
        guard let id else {
            Log.write("sound: \(label) の音が登録されていない")
            return
        }
        Log.write("sound: \(label) を鳴らす (id=\(id))")
        AudioServicesPlaySystemSound(id)
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
