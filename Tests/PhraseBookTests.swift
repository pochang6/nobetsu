import Foundation

extension Tests {
    @MainActor
    static func dictionaryLoading() {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: dir) }
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let sample = dir.appendingPathComponent("sample.txt")
            let personal = dir.appendingPathComponent("dictionary.txt")
            let legacy = dir.appendingPathComponent("legacy.txt")
            let config = dir.appendingPathComponent("dictionary-sources.json")
            let target = dir.appendingPathComponent("repo.txt")
            try Data("見本語彙 => Sample\n共通語彙 => Default\n".utf8).write(to: sample)
            var messages: [String] = []
            let book = PhraseBook(directory: dir, bundledURL: sample, writeLog: { messages.append($0) })
            book.reload()
            expect("個人辞書未作成は警告しない", book.issues.count, 0)
            try fm.createSymbolicLink(at: personal, withDestinationURL: target)
            book.reload()
            expect("初回の壊れたリンクでも同梱規則を使える", book.apply(to: "見本語彙"), "Sample")
            expect("壊れたリンクの保存先を表示", book.issues.map(\.url), [personal])
            expectContains("辞書の案内から対処へたどれる", book.issues.map(\.reason), "リンク先")
            try Data("共通語彙 => Personal\n".utf8).write(to: target)
            book.reload()
            expect("リンク先を復旧したら警告が消える", book.issues.count, 0)
            expect("個人辞書を優先", book.apply(to: "共通語彙"), "Personal")
            let stamp = try fm.attributesOfItem(atPath: target.path)[.modificationDate] as! Date
            try Data("共通語彙 => Modified\n".utf8).write(to: target)
            try fm.setAttributes([.modificationDate: stamp], ofItemAtPath: target.path)
            book.reload()
            expect("更新時刻が同じでも編集が反映される", book.apply(to: "共通語彙"), "Modified")
            try Data([0xff, 0xfe, 0xff]).write(to: target)
            book.reload()
            expect("不正なUTF-8でも同梱規則を使える", book.apply(to: "見本語彙"), "Sample")
            expect("読めなくなった辞書の古い規則を残さない", book.apply(to: "共通語彙"), "Default")
            expect("文字コードの問題も保存先を表示", book.issues.map(\.url), [personal])
            try Data("共通語彙 => Personal\n".utf8).write(to: target)
            try Data("壊れたJSON".utf8).write(to: config)
            let firstLoad = PhraseBook(directory: dir, bundledURL: sample, writeLog: { messages.append($0) })
            firstLoad.reload()
            expect("初回のJSON破損でも個人辞書を使える", firstLoad.apply(to: "共通語彙"), "Personal")
            expect("JSON破損でも同梱辞書を使える", firstLoad.apply(to: "見本語彙"), "Sample")
            expect("JSON破損の保存先を表示", firstLoad.issues.map(\.url), [config])
            let configuration = DictionaryStorage.Configuration(legacyPaths: [legacy.path])
            try JSONEncoder().encode(configuration).write(to: config)
            book.reload()
            expect("登録済み旧辞書の消失を案内", book.issues.map(\.url), [legacy])
            try Data("旧語彙 => Legacy\n共通語彙 => LegacyDefault\n".utf8).write(to: legacy)
            book.reload()
            expect("設定と旧辞書の復旧で警告が消える", book.issues.count, 0)
            expect("復旧した旧辞書を使える", book.apply(to: "旧語彙"), "Legacy")
            expect("旧辞書より個人辞書を優先", book.apply(to: "共通語彙"), "Personal")
            try fm.removeItem(at: target)
            book.reload()
            expect("リンク実体消失後も旧辞書を使える", book.apply(to: "共通語彙"), "LegacyDefault")
            try fm.removeItem(at: personal)
            try Data().write(to: legacy)
            book.reload()
            expect("意図的な削除は警告を消す", book.issues.count, 0)
            expect("削除した規則を残さない", book.apply(to: "旧語彙"), "旧語彙")
            expect("ログに個人の保存先を出さない", messages.contains { $0.contains(dir.path) }, false)
            expect("ログに規則の内容を出さない", messages.contains { $0.contains("共通語彙") || $0.contains("Personal") }, false)
        } catch {
            expect("辞書読み込みテストが完了する", String(describing: error), "success")
        }
    }
}
