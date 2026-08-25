import Foundation

/// nobetsu の、副作用を持たない部分を確かめる。
///
/// 走らせ方は `./test.sh`。
///
/// ここで見るのは「辞書の置換」「打ち込みの差分計算」「許可が無いときの案内」の3つです。
/// 前の2つは**間違えると利用者の文章を壊す**場所、最後の1つは
/// **間違えると利用者が二度と使いはじめられない**場所で、
/// どれも入力と出力だけで完結しているので、機械で確かめられます。
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
        advice()

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

    /// 文言そのものは直すたびに変わるので、**必ず要る言葉が入っているか**だけを見る
    static func expectContains(_ name: String, _ haystack: [String], _ needle: String) {
        count += 1
        guard !haystack.contains(where: { $0.contains(needle) }) else { return }
        failures += 1
        print("❌ \(name)\n     「\(needle)」が見当たりません\n     実際: \(haystack)")
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

    // MARK: - 許可が無いときの案内

    /// 許可まわりは実機でしか確かめられない、と諦めていた場所です。
    /// TCC の返事は確かに確かめられませんが、**返事を受けて何を出すか**は
    /// ただの組み立てなので、ここで押さえられます。
    /// 出す言葉を間違えると、利用者は動かない理由にたどり着けないまま終わります
    static func advice() {
        let path = "/Applications/nobetsu.app"

        // アドホック署名。許可の操作を案内しても無駄なので、文面ごと差し替わること
        var a = PermissionAdvice.make(inputMonitoring: false, accessibility: false,
                                      adhoc: true, appPath: path)
        expectContains("アドホックだと、まず署名の話をする", [a.title], "アドホック")
        expectContains("アドホックだと、ビルドし直せと言う", a.lines, "./build.sh")
        expectContains("アドホックだと、手で追加しても無駄だと言う", a.lines, "手で追加しても直りません")

        // 入力監視が無い。ここで詰まると、アクセシビリティの要求へは永遠に進まない
        a = PermissionAdvice.make(inputMonitoring: false, accessibility: false,
                                  adhoc: false, appPath: path)
        expectContains("入力監視が先", [a.title], "入力監視")
        expectContains("入力監視が何の許可かを言う", a.lines, "キーを読む許可")
        expectContains("アクセシビリティは後だと言う", a.lines, "入力監視が済んでから")
        expectContains("⌘ を長押ししても何も起きないと言う", a.lines, "⌘ を長押ししても")
        expectContains("どのアプリの話かを言う", a.lines, path)
        expect("入力監視の設定への導線を出す", a.showsInputMonitoringButton, true)
        expect("入力監視が済むまでアクセシビリティへは誘わない", a.showsAccessibilityButton, false)

        // 入力監視は済んでいて、アクセシビリティだけ足りない
        a = PermissionAdvice.make(inputMonitoring: true, accessibility: false,
                                  adhoc: false, appPath: path)
        expectContains("残りはアクセシビリティ", [a.title], "アクセシビリティ")
        expectContains("何の許可かを言う", a.lines, "他のアプリへ文字を入れる許可")
        expect("アクセシビリティの設定への導線を出す", a.showsAccessibilityButton, true)
        expect("済んだ方へは誘わない", a.showsInputMonitoringButton, false)

        // 両方付いているのに見張れない。許可した直後はたいていこれ
        a = PermissionAdvice.make(inputMonitoring: true, accessibility: true,
                                  adhoc: false, appPath: path)
        expectContains("許可のせいではないと言う", [a.title], "許可は付いていますが")
        expectContains("起動し直せと言う", a.lines, "起動し直す")
    }
}
