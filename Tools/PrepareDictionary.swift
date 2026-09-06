import Foundation

@main
struct PrepareDictionary {
    static func main() {
        let args = CommandLine.arguments
        guard args.count == 4 else { exit(2) }
        let previous = URL(fileURLWithPath: args[2])
        do {
            try DictionaryStorage.prepare(in: DictionaryStorage.directory,
                repositoryDictionary: URL(fileURLWithPath: args[1]),
                previousBundle: DictionaryStorage.exists(previous) ? previous : nil,
                sample: URL(fileURLWithPath: args[3]))
            print("==> 個人辞書を保護しました（既存ファイル・リンクは変更していません）")
        } catch {
            // パス・規則・OS の詳細エラーを公開ログへ流さない。
            fputs("個人辞書を保護できないため設置を中止しました。辞書の保存先・リンク先・書き込み権限を確認してください。旧アプリは残しています。\n", stderr)
            exit(1)
        }
    }
}
