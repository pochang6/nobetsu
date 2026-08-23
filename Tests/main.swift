import Foundation

/// nobetsu の、副作用を持たない部分を確かめる。
///
/// 走らせ方は `./test.sh`。
///
/// ここで見るのは「辞書の置換」と「打ち込みの差分計算」の2つだけです。
/// どちらも**間違えると利用者の文章を壊す**場所で、しかも入力と出力だけで
/// 完結しているので、機械で確かめられます。
///
/// 逆に、マイク・イベントタップ・他アプリへの打ち込みは実機でしか確かめられません。
/// そちらは `.claude/skills/rebuild/` の手順で、実際に動かして見ています。
@main
struct Tests {

    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var count = 0

    static func main() {
        parse()
        build()
        apply()
        diff()
        follow()

        print("")
        if failures == 0 {
            print("✅ \(count) 件すべて通りました")
            exit(0)
        }
        print("❌ \(count) 件中 \(failures) 件が失敗しました")
        exit(1)
    }

    // MARK: - 確かめる道具

    static func expect(_ name: String, _ actual: String, _ expected: String) {
        count += 1
        guard actual != expected else { return }
        failures += 1
        print("❌ \(name)\n     期待: \(expected)\n     実際: \(actual)")
    }

    static func expect(_ name: String, _ actual: Int, _ expected: Int) {
        expect(name, String(actual), String(expected))
    }

    static func expect(_ name: String, _ actual: Bool, _ expected: Bool) {
        expect(name, actual ? "true" : "false", expected ? "true" : "false")
    }

    // MARK: - 辞書を読む

    static func parse() {
        let rules = PhraseBook.parse("""
        # まるごとコメント
        苦労してくる => Cloneしてくる
        クロード → Claude
        タブ区切り\tでも書ける
          前後に空白があっても  =>  取り除かれる
        行末にコメント => つけられる   # ここは無視される

        区切りが無い行は捨てられる
        => 左が空なら捨てられる
        """)

        expect("読めた件数", rules.count, 5)
        expect("=> で割れる", rules[0].from, "苦労してくる")
        expect("=> の右", rules[0].to, "Cloneしてくる")
        expect("→ でも割れる", rules[1].to, "Claude")
        expect("タブでも割れる", rules[2].to, "でも書ける")
        expect("前後の空白は落ちる", rules[3].from, "前後に空白があっても")
        expect("行末コメントは落ちる", rules[4].to, "つけられる")
    }

    // MARK: - 規則を整える

    static func build() {
        let built = PhraseBook.build(from: [
            ("苦労", "Clone"),
            ("苦労してくる", "Cloneしてくる"),
            ("品予約履歴", "備品予約履歴"),      // 自滅する。捨てられるはず
            ("クロード", "クロード先生"),        // これも自滅する。「クロード先生先生」になる
            ("クロード", "Claude"),
            ("クロード", "Claude Code"),          // 後勝ち
        ])

        expect("自滅する規則は捨てられる", built.rejected.count, 2)
        expect("捨てた理由が分かる", built.rejected[0], "品予約履歴 => 備品予約履歴")
        expect("右に左が含まれるものも捨てる", built.rejected[1], "クロード => クロード先生")
        expect("残った件数", built.rules.count, 3)
        expect("長い規則が先に来る", built.rules[0].from, "苦労してくる")
        expect("同じ左辺は後勝ち", built.rules.first { $0.from == "クロード" }?.to ?? "", "Claude Code")

        // 並び順が毎回変わると結果も変わってしまうので、決まった順になること
        let again = PhraseBook.build(from: [
            ("あいう", "A"), ("かきく", "B"), ("さしす", "C"),
        ])
        expect("同じ長さなら左辺の順に並ぶ", again.rules.map(\.from).joined(separator: ","), "あいう,かきく,さしす")
    }

    // MARK: - 辞書を当てる

    static func apply() {
        let rules = PhraseBook.build(from: [
            ("苦労してくる", "Cloneしてくる"),
            ("クロードコード", "Claude Code"),
            ("プライマリー機", "プライマリーキー"),
        ]).rules

        expect("置き換わる", PhraseBook.apply("苦労してくるね", rules: rules), "Cloneしてくるね")
        expect("関係ない文はそのまま", PhraseBook.apply("今日は苦労した", rules: rules), "今日は苦労した")
        expect("複数当たる",
               PhraseBook.apply("クロードコードで苦労してくる", rules: rules),
               "Claude CodeでCloneしてくる")
        expect("空文字はそのまま", PhraseBook.apply("", rules: rules), "")
        expect("規則が無ければそのまま", PhraseBook.apply("苦労してくる", rules: []), "苦労してくる")

        // **直した結果を、もう一度直しにいかないこと。**
        // 未確定テキストは同じ区間が何度も届くので、ここが崩れると打ち直すたびに壊れていく
        let once = PhraseBook.apply("クロードコードで苦労してくる", rules: rules)
        expect("二度当てても変わらない", PhraseBook.apply(once, rules: rules), once)

        // 短い規則と長い規則が両方あっても、長い方が勝つ
        let both = PhraseBook.build(from: [("苦労", "Clone"), ("苦労してくる", "Cloneしてくる")]).rules
        expect("長い方が勝つ", PhraseBook.apply("苦労してくるよ", rules: both), "Cloneしてくるよ")
    }

    // MARK: - 打ち込みの差分

    static func diff() {
        func d(_ a: String, _ b: String) -> (delete: Int, insert: String) {
            TextInjector.diff(pending: Array(a), next: Array(b))
        }

        var r = d("こんにちは", "こんにちは世界")
        expect("続きが伸びたら消さない", r.delete, 0)
        expect("続きだけ打つ", r.insert, "世界")

        // 「こん」までは同じ。「にちは」の3文字を消して「ばんは」を打ち直す
        r = d("こんにちは", "こんばんは")
        expect("食い違った分だけ消す", r.delete, 3)
        expect("食い違った分だけ打ち直す", r.insert, "ばんは")

        r = d("こんにちは", "こんにちは")
        expect("同じなら何もしない", r.delete, 0)
        expect("同じなら何も打たない", r.insert, "")

        r = d("こんにちは", "")
        expect("空になったら全部消す", r.delete, 5)
        expect("空になったら何も打たない", r.insert, "")

        r = d("", "はじめまして")
        expect("白紙からは消さない", r.delete, 0)
        expect("白紙からは全部打つ", r.insert, "はじめまして")

        // 絵文字や結合文字を1文字として数えること。
        // バイト数で数えると、消しすぎて利用者の文章を削る
        r = d("あ🇯🇵", "あ🇯🇵い")
        expect("国旗も1文字として数える", r.delete, 0)
        expect("国旗の後ろに足せる", r.insert, "い")
    }

    // MARK: - 送信済みの文章を追いかけない

    static func follow() {
        // virtualPrefix = 「打ち込み済みと見なしているが、実際には画面に無い文字数」
        // ＝ 送信し終えて、こちらの手から離れた文章の長さ

        expect("送信していないなら、いつでも当てられる",
               TextInjector.canFollow(pending: Array("こんにちは"), next: Array("こんばんは"), virtualPrefix: 0),
               true)

        expect("送信済みの部分がそのままなら、続きを当てられる",
               TextInjector.canFollow(pending: Array("送信した。続き"), next: Array("送信した。続きです"), virtualPrefix: 5),
               true)

        // ここが崩れると、送信し終えた文章が丸ごと次の入力欄へ打ち込まれる。実際に起きた
        expect("送信済みの部分が書き直されたら、追いかけない",
               TextInjector.canFollow(pending: Array("送信した。続き"), next: Array("送信しました。続き"), virtualPrefix: 5),
               false)
    }
}
