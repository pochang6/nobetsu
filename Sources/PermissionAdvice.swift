import Foundation

/// 許可が足りていないときに、利用者へ何を伝えるかを組み立てる。
///
/// **ここには副作用がありません。**状態を渡すと文言が返るだけなので `./test.sh` で確かめられます。
/// TCC の返事やイベントタップの生成は実機でしか確かめられないので、
/// 「何を出すか」の判断だけをこちら側へ寄せてあります。
///
/// 分けた理由はもう一つあって、**ここを間違えると利用者が永久に詰まります。**
/// 入力監視が拒否されている間、アプリはアクセシビリティの要求へ進みません
/// （順番を入れ替えると入力監視の要求そのものが通らなくなる既知の不具合があるため）。
/// 黙って止まっていると「壊れている」としか見えないので、その状態を必ず言葉にします。
///
/// メニューに1項目ずつ並ぶので、**1行は短く。**長い文を1行に詰めるとメニューが横に伸びます。
struct PermissionAdvice: Equatable {

    /// メニューの先頭に出す一行。いま何が起きているか
    let title: String
    /// その下に並べる説明。1要素が1項目
    let lines: [String]
    /// 設定画面への導線を出すか
    let showsInputMonitoringButton: Bool
    let showsAccessibilityButton: Bool

    /// 許可の一覧に載るのは「そのパスにあるアプリ」です。
    /// リポジトリの中で動かしたものと `/Applications` のものは別扱いになるため、
    /// いまどれが動いているのかを必ず見せます
    private static func pathLines(_ appPath: String) -> [String] {
        [
            "いま動いているのは \(appPath) です。",
            "設定の一覧でも、同じものを選んでください。",
        ]
    }

    /// 許可が無い間は ⌘ の長押しも無反応です。
    /// 「押せば聞かれるだろう」と待たれると、そこで詰みます
    private static let noPromptOnHold = [
        "許可が無い間は、⌘ を長押ししても何も起きません。",
        "そこで許可を聞かれることもありません。",
    ]

    static func make(inputMonitoring: Bool,
                     accessibility: Bool,
                     adhoc: Bool,
                     appPath: String) -> PermissionAdvice {

        // アドホック署名は他のすべてに優先します。
        // 許可の操作をいくら案内しても、この状態では入力監視が下りないためです
        if adhoc {
            return PermissionAdvice(
                title: "アドホック署名のため、許可を受け取れません",
                lines: [
                    "macOS は許可を「署名の同一性」で覚えます。",
                    "アドホック署名にはそれが無く、入力監視は尋ねられずに拒否されます。",
                    "自己署名証明書「nobetsu」を作り、./build.sh をやり直してください。",
                    "手順は README の「ソースからビルドする前に」にあります。",
                    "設定画面で手で追加しても直りません。次のビルドでまた別扱いになります。",
                ] + pathLines(appPath),
                showsInputMonitoringButton: true,
                showsAccessibilityButton: false)
        }

        if !inputMonitoring {
            return PermissionAdvice(
                title: "入力監視が許可されていません",
                lines: [
                    "入力監視は「キーを読む許可」です。",
                    "⌘ の長押しを待ち受けるために要ります。",
                    "アクセシビリティは、入力監視が済んでから求めます。",
                    "先に触ると、入力監視の要求そのものが通らなくなるためです。",
                ] + noPromptOnHold + pathLines(appPath),
                showsInputMonitoringButton: true,
                showsAccessibilityButton: false)
        }

        if !accessibility {
            return PermissionAdvice(
                title: "アクセシビリティが許可されていません",
                lines: [
                    "入力監視は許可されています。残りはこれだけです。",
                    "アクセシビリティは「他のアプリへ文字を入れる許可」です。",
                    "無いままだと、声は聞こえていても文字が入りません。",
                ] + noPromptOnHold + pathLines(appPath),
                showsInputMonitoringButton: false,
                showsAccessibilityButton: true)
        }

        // 両方付いているのに見張れない。許可の判定はプロセスの起動時に固まるので、
        // 「許可した直後」はたいていこれです
        return PermissionAdvice(
            title: "許可は付いていますが、キーを見張れません",
            lines: [
                "許可の判定は、アプリの起動時に固まります。",
                "nobetsu を起動し直すと直ることがあります。",
                "設定の一覧に古い nobetsu が残っていたら、外して追加し直してください。",
            ] + pathLines(appPath),
            showsInputMonitoringButton: true,
            showsAccessibilityButton: true)
    }
}
