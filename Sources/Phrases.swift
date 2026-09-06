import Foundation
import AppKit

/// 言い換え表（辞書）。認識結果を打ち込む直前に書き換える。
///
/// 音声認識は「Clone」を「苦労」と書く。話し言葉としては正しいので、
/// 認識器を責めても直らない。**打つ前にこちらで直す**のが唯一の現実的な手当て。
///
/// 公開サンプル → 旧形式のローカル辞書（あれば）→ 個人辞書の順に読む。
/// 個人の語彙はアプリへ焼き込まない。同じ左辺は後のファイルが勝つ。
/// ファイル・リンクは利用者のもの。更新時にも上書きや削除をしない。
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
        DictionaryStorage.directory.appendingPathComponent("dictionary.txt")
    }

    // MARK: - 読み込み

    private func files() throws -> [URL] {
        DictionaryStorage.unique([PhraseBook.bundledURL].compactMap { $0 }
            + (try DictionaryStorage.legacyURLs(in: DictionaryStorage.directory))
            + [PhraseBook.personalURL])
    }

    func reloadIfNeeded() {
        do {
            let files = try files()
            var nextStamps: [URL: Date] = [:]
            for url in files where DictionaryStorage.exists(url) {
                let path = url.resolvingSymlinksInPath().path
                let attrs = try FileManager.default.attributesOfItem(atPath: path)
                nextStamps[url] = attrs[.modificationDate] as? Date
            }
            guard stamps != nextStamps || rules.isEmpty else { return }
            try load(files)
            stamps = nextStamps
        } catch {
            // 読めないときは最後に読めた辞書を維持する。中身・個人パスはログへ渡さない。
            Log.write("phrases: 辞書を読み込めないため直前の規則を維持した。保存先・リンク先を確認してください")
        }
    }

    func reload() {
        stamps = [:]
        reloadIfNeeded()
    }

    private func load(_ files: [URL]) throws {
        var pairs: [Rule] = []
        var counts: [String] = []
        for (index, url) in files.enumerated() where DictionaryStorage.exists(url) {
            let text = try String(contentsOf: url, encoding: .utf8)
            let parsed = PhraseBook.parse(text)
            pairs.append(contentsOf: parsed)
            counts.append("辞書\(index + 1)=\(parsed.count)")
        }
        let built = PhraseBook.build(from: pairs)
        rules = built.rules
        if !built.rejected.isEmpty {
            Log.write("phrases: 左辺が右辺に含まれる規則を \(built.rejected.count) 件除外した")
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
        do {
            try DictionaryStorage.createIfMissing(Data(PhraseBook.template.utf8), at: url)
            guard FileManager.default.isReadableFile(atPath: url.path) else {
                throw CocoaError(.fileReadNoPermission)
            }
            NSWorkspace.shared.open(url)
        } catch {
            let alert = NSAlert()
            alert.messageText = "個人辞書を開けませんでした"
            alert.informativeText = "既存のファイル・リンクは上書きしていません。保存先の権限やリンク先を確認してください。"
            alert.runModal()
        }
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
