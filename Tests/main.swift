import Foundation
import Compression

/// nobetsu の、副作用を持たない部分を確かめる。
///
/// 走らせ方は `./test.sh`。
///
/// ここで見るのは、辞書の置換、打ち込みの差分計算、許可が無いときの案内、
/// 開始キーの設定、ログの圧縮です。間違えると利用者の文章・起動手順・
/// 過去の記録を壊す場所で、入力と出力だけで完結するため機械で確かめられます。
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
        triggerSettings()
        archive()
        dictionaryStorage()
        dictationLifecycle()
        indicatorPlacement()

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

    // MARK: - ログの退避（gzip）

    // MARK: - 開始キー

    static func triggerSettings() {
        expect("左だけなら左⌘を受ける", CommandKeyChoice.left.accepts(keyCode: 55), true)
        expect("左だけなら右⌘を受けない", CommandKeyChoice.left.accepts(keyCode: 54), false)
        expect("右だけなら右⌘を受ける", CommandKeyChoice.right.accepts(keyCode: 54), true)
        expect("左右なら左⌘を受ける", CommandKeyChoice.both.accepts(keyCode: 55), true)
        expect("左右なら右⌘を受ける", CommandKeyChoice.both.accepts(keyCode: 54), true)
        expect("⌘以外は受けない", CommandKeyChoice.both.accepts(keyCode: 8), false)

        expect("長押しは0.1秒刻みに丸める",
               Int(TriggerSettings.normalizedHoldThreshold(0.84) * 10), 8)
        expect("長押しの下限",
               Int(TriggerSettings.normalizedHoldThreshold(0.1) * 10), 5)
        expect("長押しの上限",
               Int(TriggerSettings.normalizedHoldThreshold(9.0) * 10), 20)
        expect("長押しの既定は1秒",
               Int(TriggerSettings.defaultHoldThreshold * 10), 10)
    }

    /// ログは追記しかしないので、放っておくと際限なく育つ。
    /// 1MB で圧縮して退避するようにしたが、**圧縮が壊れていても普段は誰も気づかない**。
    /// 気づくのは半年後、いざ古い記録を読もうとして開けなかったときになる。
    /// gzip の形（ヘッダ・CRC32・元の長さ）は入力と出力だけで決まるので、ここで確かめておく。
    static func archive() {
        expect("退避先の名前", Log.archiveName("nobetsu.log", 1, compressed: true), "nobetsu.log.1.gz")
        expect("圧縮できなかったときは .gz を付けない",
               Log.archiveName("nobetsu.log", 3, compressed: false), "nobetsu.log.3")

        // CRC32 の答え合わせ。"123456789" が 0xCBF43926 になるのは規格が決めた検算値で、
        // ここがずれていると gunzip は最後の最後で「壊れている」と言って捨てる
        expect("CRC32 の検算値",
               String(format: "%08X", Log.crc32(Data("123456789".utf8))), "CBF43926")

        let line = "[00:00:00.000] focus: 入力先を見張る（Claude）\n"
        let sample = Data(String(repeating: line, count: 400).utf8)
        guard let packed = Log.gzipped(sample, mtime: 0) else {
            count += 1
            failures += 1
            print("❌ gzip に包めなかった")
            return
        }

        expect("gzip の魔法の2バイト", String(format: "%02X%02X", packed[0], packed[1]), "1F8B")
        expect("中身は DEFLATE", String(format: "%02X", packed[2]), "08")
        expect("ログは1割以下に縮む", packed.count < sample.count / 10, true)

        // 末尾4バイトは元の長さ。gunzip はここで長さを照合する
        let size = packed.suffix(4).reversed().reduce(0) { $0 << 8 | Int($1) }
        expect("末尾に元の長さが入る", size, sample.count)

        // その手前の4バイトは CRC32
        let crc = packed.dropLast(4).suffix(4).reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        expect("末尾に CRC32 が入る",
               String(format: "%08X", crc), String(format: "%08X", Log.crc32(sample)))

        // ヘッダ10バイトと末尾8バイトを外すと、生の DEFLATE が残るはず。
        // 戻して元と同じなら、gunzip も同じように戻せる
        let body = Data(packed.dropFirst(10).dropLast(8))
        expect("包みを解くと元に戻る", inflate(body, into: sample.count) == sample, true)

        expect("空でも壊れた形にはしない", (Log.gzipped(Data())?.count ?? 0) > 0, true)
        expect("標準の gzip が読める", gzipAccepts(packed), true)
    }

    /// 同じ Compression API で戻せるだけでは、gzip 互換とは言い切れない。
    /// macOS 標準の gzip 自身にも形式を検査してもらう。
    static func gzipAccepts(_ data: Data) -> Bool {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nobetsu-log-test-\(UUID().uuidString).gz")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try data.write(to: url)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
            process.arguments = ["-t", url.path]
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// テストのためだけの解凍。アプリ本体は圧縮しかしないので、こちらに置く
    static func inflate(_ data: Data, into capacity: Int) -> Data? {
        data.withUnsafeBytes { raw -> Data? in
            guard let src = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity + 1)
            defer { dst.deallocate() }
            let n = compression_decode_buffer(dst, capacity + 1, src, data.count, nil, COMPRESSION_ZLIB)
            guard n > 0 else { return nil }
            return Data(bytes: dst, count: n)
        }
    }
}
