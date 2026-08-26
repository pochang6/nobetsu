import Foundation

@main
struct Manage {

    static func main() {
        do {
            var args = Array(CommandLine.arguments.dropFirst())
            var path = "dictionary.txt"
            if args.first == "--file" {
                guard args.count >= 3 else { return usage() }
                path = args[1]
                args.removeFirst(2)
            }
            guard let command = args.first else { return usage() }
            args.removeFirst()

            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            let text = try String(contentsOf: url, encoding: .utf8)

            switch command {
            case "find":
                guard args.count == 1 else { return usage() }
                show(DictionaryEditor.find(args[0], in: text))
            case "set":
                guard args.count == 2 else { return usage() }
                let result = try DictionaryEditor.upsert(from: args[0], to: args[1], in: text)
                try commit(result.0, change: result.1, to: url)
            case "replace":
                guard args.count == 3 else { return usage() }
                let result = try DictionaryEditor.replace(oldFrom: args[0], newFrom: args[1], newTo: args[2], in: text)
                try commit(result.0, change: result.1, to: url)
            case "delete":
                guard args.count == 1 else { return usage() }
                let result = try DictionaryEditor.delete(from: args[0], in: text)
                try commit(result.0, change: result.1, to: url)
            default:
                usage()
            }
        } catch {
            fputs("❌ \(error)\n", stderr)
            exit(1)
        }
    }

    static func show(_ matches: [DictionaryEditor.Match]) {
        guard !matches.isEmpty else {
            print("候補は見つかりませんでした")
            return
        }
        for match in matches {
            let kind = match.entry.candidate ? "候補" : "本登録"
            let reason = match.exact ? "完全" : "部分「\(match.fragment)」"
            print("\(match.entry.line): [\(kind) / \(reason)] \(match.entry.raw)")
        }
    }

    static func commit(_ next: String, change: DictionaryEditor.Change, to url: URL) throws {
        try validate(next)
        try next.write(to: url, atomically: true, encoding: .utf8)
        switch change {
        case .inserted(let line): print("✅ 追加しました（\(line) 行目）")
        case .updated(let line): print("✅ 更新しました（\(line) 行目）")
        case .promoted(let line): print("✅ 候補から本登録へ移しました（\(line) 行目）")
        case .replaced(let line): print("✅ 置換しました（\(line) 行目）")
        case .deleted(let line): print("✅ 削除しました（元 \(line) 行目）")
        }
    }

    /// 書く前に、アプリと同じ実装で辞書全体を検証する。
    static func validate(_ text: String) throws {
        let pairs = PhraseBook.parse(text)
        var seen: [String: String] = [:]
        for rule in pairs {
            if let before = seen[rule.from], before != rule.to {
                throw DictionaryEditor.EditError.invalid("同じ左辺「\(rule.from)」に異なる右辺があります")
            }
            seen[rule.from] = rule.to
        }
        let built = PhraseBook.build(from: pairs)
        if let rejected = built.rejected.first {
            throw DictionaryEditor.EditError.invalid("アプリが捨てる規則があります: \(rejected)")
        }
        for rule in built.rules {
            let again = PhraseBook.apply(rule.to, rules: built.rules)
            if again != rule.to {
                throw DictionaryEditor.EditError.invalid("正しい文字を壊す衝突があります: 「\(rule.to)」→「\(again)」")
            }
        }
    }

    static func usage() {
        print("""
        使い方:
          manage.sh [--file PATH] find QUERY
          manage.sh [--file PATH] set FROM TO
          manage.sh [--file PATH] replace OLD_FROM NEW_FROM NEW_TO
          manage.sh [--file PATH] delete FROM

        set は、左辺があれば更新、無ければ追加する upsert です。
        find は完全一致を先に探し、無ければ部分候補を長い順に表示します。
        replace/delete の OLD_FROM/FROM は完全一致した1件だけを変更します。
        """)
        exit(2)
    }
}
