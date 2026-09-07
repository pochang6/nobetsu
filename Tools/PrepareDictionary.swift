import Foundation

@main
struct PrepareDictionary {
    static func main() {
        let args = CommandLine.arguments
        guard args.count == 4 else { exit(2) }
        let previous = URL(fileURLWithPath: args[2])
        do {
            let issues = try DictionaryStorage.prepare(in: DictionaryStorage.directory,
                repositoryDictionary: URL(fileURLWithPath: args[1]),
                previousBundle: DictionaryStorage.hasEntry(previous) ? previous : nil,
                sample: URL(fileURLWithPath: args[3]))
            if !issues.isEmpty {
                print("⚠️ 読めない辞書・引き継ぎ記録があります。既存データを維持して設置を続けます。起動後のメニューで保存先を確認してください。")
            }
            print("==> 個人辞書を保護しました（既存ファイル・リンクは変更していません）")
        } catch {
            // パス・規則・OS の詳細エラーを公開ログへ流さない。
            fputs("個人辞書を保護できないため設置を中止しました。辞書の保存先・リンク先・書き込み権限を確認してください。旧アプリは残しています。\n", stderr)
            exit(1)
        }
    }
}
