import Foundation

/// 辞書全体を点検する（辞書スキルのレベル3で使う道具）。
///
/// 走らせ方は `.claude/skills/dictionary/check.sh`。
///
/// 見ているのは1つだけです。
/// **辞書のすべての右辺（＝すでに正しい文字）に、辞書全体を当て直す。**
/// そこで何かが書き換わるなら、その辞書は正しい文章を壊します。
///
/// 規則は1本ずつ正しくても、束にすると壊れます。
/// 辞書は上から順に全部当てるので、先に直した結果を後ろの規則がもう一度直しにいくためです。
/// 数が増えると人間の目では追えなくなるので、機械にやらせます。
///
/// 判定にはアプリと同じ `PhraseBook`（Sources/Phrases.swift）を使います。
/// ここだけ別の実装にすると、通ったのに本番で壊れる、という一番たちの悪い形になります。
@main
struct Check {

    nonisolated(unsafe) static var fatal = 0
    nonisolated(unsafe) static var warn = 0

    static func main() {
        var paths: [String] = []
        var target: String?
        var args = Array(CommandLine.arguments.dropFirst())

        while let arg = args.first {
            args.removeFirst()
            if arg == "--on" {
                target = args.first
                if !args.isEmpty { args.removeFirst() }
            } else {
                paths.append(arg)
            }
        }
        if paths.isEmpty {
            do {
                let personal = DictionaryStorage.directory.appendingPathComponent("dictionary.txt")
                let repo = URL(fileURLWithPath: "dictionary.txt")
                let urls = [URL(fileURLWithPath: "dictionary.sample.txt")]
                    + (try DictionaryStorage.legacyURLs(in: DictionaryStorage.directory))
                    + (DictionaryStorage.hasEntry(repo) ? [repo] : []) + [personal]
                paths = DictionaryStorage.unique(urls).filter { DictionaryStorage.hasEntry($0) }.map(\.path)
            } catch {
                print("❌ 辞書の引き継ぎ記録を読めません。保存フォルダを確認してください。")
                exit(1)
            }
        }

        // 読む
        var pairs: [PhraseBook.Rule] = []
        for path in paths {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
                print("❌ 読めません: \(path)")
                exit(1)
            }
            let parsed = PhraseBook.parse(text)
            print("読んだ: \(path) — \(parsed.count) 件")
            pairs.append(contentsOf: parsed)
        }
        print("")

        duplicates(pairs)

        let built = PhraseBook.build(from: pairs)
        rejected(built.rejected)
        idempotent(built.rules)
        tooShort(built.rules)

        if let target { applyTo(target, built.rules) }

        print("")
        print("規則 \(built.rules.count) 件")
        if fatal > 0 {
            print("❌ 直さないといけないもの \(fatal) 件 / 見ておくもの \(warn) 件")
            exit(1)
        }
        if warn > 0 {
            print("⚠️  見ておくもの \(warn) 件（壊れてはいません）")
            exit(0)
        }
        print("✅ 壊れているところはありません")
    }

    // MARK: - 同じ左が二度

    /// 後に書いた方が勝つので、先に書いた方は**黙って消えます**。
    /// 消えたことに気づかないまま「登録したのに効かない」と悩む形になるので、出しておきます。
    static func duplicates(_ pairs: [PhraseBook.Rule]) {
        var seen: [String: String] = [:]
        for rule in pairs {
            if let before = seen[rule.from], before != rule.to {
                warn += 1
                print("⚠️  同じ左が二度あります。後の方が勝ちます")
                print("      \(rule.from) => \(before)   ← 消える")
                print("      \(rule.from) => \(rule.to)")
            }
            seen[rule.from] = rule.to
        }
    }

    // MARK: - アプリが捨てる規則

    static func rejected(_ list: [String]) {
        for line in list {
            fatal += 1
            print("❌ 左が右の一部です。アプリが読み込み時に捨てます")
            print("      \(line)")
            print("      前に一文字足して、右に含まれない形にしてください")
        }
    }

    // MARK: - すでに正しい文字を、もう一度直しにいっていないか

    static func idempotent(_ rules: [PhraseBook.Rule]) {
        for rule in rules {
            let again = PhraseBook.apply(rule.to, rules: rules)
            guard again != rule.to else { continue }
            fatal += 1
            print("❌ すでに正しい文字が書き換わります")
            print("      「\(rule.to)」→「\(again)」")
            let culprits = rules.filter { $0.from != rule.from && rule.to.contains($0.from) }
            for c in culprits {
                print("      犯人: \(c.from) => \(c.to)")
            }
            print("      → 犯人の左を伸ばすか、候補（#?）へ落としてください")
        }
    }

    // MARK: - 短すぎる左

    static func tooShort(_ rules: [PhraseBook.Rule]) {
        for rule in rules where rule.from.count <= 2 {
            // 英数字だけの略語（MCP など）は短くても当たり先が限られるので数えない
            let japanese = rule.from.unicodeScalars.contains { $0.value > 0x3000 }
            guard japanese else { continue }
            warn += 1
            print("⚠️  左が短すぎます。関係ない場面で当たります: \(rule.from) => \(rule.to)")
        }
    }

    // MARK: - 過去の文章に当ててみる

    static func applyTo(_ path: String, _ rules: [PhraseBook.Rule]) {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            print("❌ 読めません: \(path)")
            fatal += 1
            return
        }
        print("")
        print("―― \(path) に当てた結果（変わった行だけ）――")
        var changed = 0
        for (i, line) in text.components(separatedBy: .newlines).enumerated() {
            let after = PhraseBook.apply(line, rules: rules)
            guard after != line else { continue }
            changed += 1
            print("  \(i + 1): - \(line)")
            print("  \(i + 1): + \(after)")
        }
        if changed == 0 { print("  変わった行はありません") }
        print("―― \(changed) 行 ――")
        print("**壊れている行が混じっていないか、目で見てください。**")
    }
}
