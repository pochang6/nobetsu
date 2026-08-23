import Foundation
import AppKit

/// 言い換え表（辞書）。認識結果を打ち込む直前に書き換える。
///
/// 音声認識は「Clone」を「苦労」と書く。話し言葉としては正しいので、
/// 認識器を責めても直らない。**打つ前にこちらで直す**のが唯一の現実的な手当て。
///
/// 辞書は2枚ある。読む順番に意味がある。
///
/// 1. 同梱辞書 — リポジトリの `dictionary.txt`。`build.sh` がアプリへ焼き込む。
///    git で管理されるので、複数の Mac で同じ辞書を共有できる
/// 2. 個人辞書 — `~/Library/Application Support/nobetsu/dictionary.txt`。
///    その Mac だけの調整。**ビルドし直さずに直せる**
///
/// 同じ「認識結果」が両方にあれば個人辞書が勝つ。
/// 読み込むのは認識を始める瞬間なので、書き換えたら次に喋れば反映される。
@MainActor
final class PhraseBook {

    static let shared = PhraseBook()

    typealias Rule = (from: String, to: String)

    private(set) var rules: [Rule] = []
    /// 直近に読み込んだファイルとその更新時刻。中身が変わっていなければ読み直さない
    private var stamps: [URL: Date] = [:]

    /// 同梱辞書（アプリの中）
    static var bundledURL: URL? {
        Bundle.main.url(forResource: "dictionary", withExtension: "txt")
    }

    /// 個人辞書（この Mac だけ）
    static var personalURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appending(path: "nobetsu/dictionary.txt")
    }

    // MARK: - 読み込み

    /// 変わっていれば読み直す。認識を始めるたびに呼ぶので、軽くしておく
    func reloadIfNeeded() {
        let files = [PhraseBook.bundledURL, PhraseBook.personalURL].compactMap { $0 }
        var changed = false
        for url in files {
            // シンボリックリンクの先を見る。
            // 個人辞書をリポジトリの辞書へのリンクにしている場合、
            // リンク自身の更新時刻は中身を書き換えても変わらない
            let path = url.resolvingSymlinksInPath().path
            let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
            if stamps[url] != modified {
                stamps[url] = modified
                changed = true
            }
        }
        guard changed || rules.isEmpty else { return }
        load(files)
    }

    func reload() {
        stamps = [:]
        load([PhraseBook.bundledURL, PhraseBook.personalURL].compactMap { $0 })
    }

    private func load(_ files: [URL]) {
        var pairs: [Rule] = []
        var counts: [String] = []

        for url in files {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let parsed = PhraseBook.parse(text)
            // 後から読んだ方（個人辞書）が勝つ
            pairs.append(contentsOf: parsed)
            counts.append("\(url.lastPathComponent)=\(parsed.count)")
        }

        let built = PhraseBook.build(from: pairs)
        rules = built.rules
        for rejected in built.rejected {
            Log.write("phrases: 「\(rejected)」は左が右の一部なので使わない")
        }
        Log.write("phrases: 辞書を読み込んだ \(rules.count) 件 [\(counts.joined(separator: " "))]")
    }

    /// 読み込んだ組を、当てられる形に整える。
    ///
    /// **左が右の一部になっている規則は捨てる。**
    /// 「品予約履歴 => 備品予約履歴」を許すと、正しく「備品予約履歴」と認識されたときにも
    /// 中の「品予約履歴」が引っかかり、「備備品予約履歴」になる。
    /// 直したものを、もう一度直しにいってしまう。直せば直すほど壊れる規則なので、使わない。
    ///
    /// **長い言い回しから先に当てる。**
    /// 「苦労」より「苦労してくる」を先に見ないと、短い方に食われる。
    /// 同じ長さのときは左辺の順に並べる。並び順が毎回変わると、結果も変わってしまう。
    ///
    /// 副作用が無いので、ここだけ取り出して確かめられる（`./test.sh`）
    nonisolated static func build(from pairs: [Rule]) -> (rules: [Rule], rejected: [String]) {
        var table: [String: String] = [:]
        var rejected: [String] = []

        for rule in pairs {
            if rule.to.contains(rule.from) {
                rejected.append("\(rule.from) => \(rule.to)")
                continue
            }
            table[rule.from] = rule.to
        }

        var rules: [Rule] = table.map { (from: $0.key, to: $0.value) }
        rules.sort { a, b in
            if a.from.count != b.from.count { return a.from.count > b.from.count }
            return a.from < b.from
        }

        return (rules, rejected)
    }

    // MARK: - 適用

    /// 認識結果を、打ちたい文字列へ書き換える。
    ///
    /// 未確定テキストは毎回「その区間の全文」が届くので、
    /// ここは前後の状態を持たない純粋な置換でよい。
    /// 途中で一瞬おかしな形に化けても、次の更新で正しく打ち直される。
    func apply(to text: String) -> String {
        PhraseBook.apply(text, rules: rules)
    }

    /// 副作用が無いので、ここだけ取り出して確かめられる（`./test.sh`）
    nonisolated static func apply(_ text: String, rules: [Rule]) -> String {
        guard !rules.isEmpty, !text.isEmpty else { return text }
        var out = text
        for rule in rules {
            guard out.contains(rule.from) else { continue }
            out = out.replacingOccurrences(of: rule.from, with: rule.to)
        }
        return out
    }

    // MARK: - 解析

    /// 1行1組。区切りは `=>` か `→` かタブ。`#` から行末まではコメント
    nonisolated static func parse(_ text: String) -> [Rule] {
        var result: [Rule] = []

        for rawLine in text.components(separatedBy: .newlines) {
            var line = rawLine
            if let hash = line.firstIndex(of: "#") { line = String(line[line.startIndex..<hash]) }
            line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            var parts: [String]?
            for separator in ["=>", "→", "\t"] where line.contains(separator) {
                parts = line.components(separatedBy: separator)
                break
            }
            guard let parts, parts.count >= 2 else { continue }

            let from = parts[0].trimmingCharacters(in: .whitespaces)
            let to = parts[1...].joined().trimmingCharacters(in: .whitespaces)
            guard !from.isEmpty else { continue }
            result.append((from, to))
        }
        return result
    }

    // MARK: - 編集

    /// 個人辞書を開く。無ければ、書き方の分かる雛形を作ってから開く
    func openPersonalFile() {
        let url = PhraseBook.personalURL
        let fm = FileManager.default

        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            try? PhraseBook.template.write(to: url, atomically: true, encoding: .utf8)
            Log.write("phrases: 個人辞書を作った \(url.path)")
        }
        NSWorkspace.shared.open(url)
    }

    private static let template = """
    # nobetsu の個人辞書（この Mac だけ）
    #
    #   認識結果 => 打ちたい文字
    #
    # 左に「音声認識が書いてしまう文字」、右に「本当に打ちたい文字」を書きます。
    # 保存したら、次に喋りはじめた時点で反映されます。ビルドし直す必要はありません。
    #
    # 短い言葉を左に置くと、関係ない場面まで書き換わります。
    # 「苦労」ではなく「苦労してくる」のように、少し長めに取るのが安全です。
    #
    # 例:
    # クロードコード => Claude Code
    # 苦労してくる => Cloneしてくる

    """
}
