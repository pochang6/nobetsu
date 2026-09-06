import Foundation

extension Tests {
    static func dictionaryStorage() {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let sample = root.appendingPathComponent("sample.txt")
            let old = root.appendingPathComponent("old.txt")
            try Data("見本 => Sample\n".utf8).write(to: sample)
            try Data("旧語彙 => Legacy\n".utf8).write(to: old)
            func scenario(_ name: String) throws -> (URL, URL, URL) {
                let directory = root.appendingPathComponent(name)
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                return (directory, directory.appendingPathComponent("repo.txt"),
                        directory.appendingPathComponent("dictionary.txt"))
            }
            func prepare(_ dir: URL, _ repo: URL) throws {
                try DictionaryStorage.prepare(in: dir, repositoryDictionary: repo,
                                              previousBundle: old, sample: sample)
            }

            let (dir, repo, personal) = try scenario("existing")
            let personalData = Data("個人語彙 => Personal\n# コメントも保護\n".utf8)
            let repoData = Data("独自語彙 => Custom\n".utf8)
            try personalData.write(to: personal)
            try repoData.write(to: repo)
            try prepare(dir, repo)
            expect("個人辞書をバイト単位で保持", try Data(contentsOf: personal) == personalData, true)
            expect("旧リポジトリ辞書も保持", try Data(contentsOf: repo) == repoData, true)
            expect("別々の辞書を引き継ぐ", try DictionaryStorage.legacyURLs(in: dir), [repo])
            try Data("# 削除済み\n".utf8).write(to: repo)
            try prepare(dir, repo)
            expect("再更新で削除済み規則を復活させない", try String(contentsOf: repo, encoding: .utf8), "# 削除済み\n")
            expect("同じ旧辞書を重複登録しない", try DictionaryStorage.legacyURLs(in: dir).count, 1)
            let backups = try fm.contentsOfDirectory(at: dir.appendingPathComponent("dictionary-backups"),
                                                     includingPropertiesForKeys: nil)
            expect("更新前の辞書を毎回退避", backups.count, 2)
            let saved = try backups.flatMap { try fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) }
            expect("元の個人辞書をバックアップから復元できる",
                   saved.contains { (try? Data(contentsOf: $0)) == personalData }, true)

            let (linkDir, linkRepo, linkPersonal) = try scenario("link")
            try repoData.write(to: linkRepo)
            try fm.createSymbolicLink(at: linkPersonal, withDestinationURL: linkRepo)
            let originalLink = try fm.destinationOfSymbolicLink(atPath: linkPersonal.path)
            try prepare(linkDir, linkRepo)
            expect("既存リンクを保持", try fm.destinationOfSymbolicLink(atPath: linkPersonal.path), originalLink)
            expect("リンク先の辞書を保持", try Data(contentsOf: linkRepo) == repoData, true)
            expect("リンク先が同じなら旧辞書を重ねない", try DictionaryStorage.legacyURLs(in: linkDir).count, 0)

            let (newDir, newRepo, newPersonal) = try scenario("repository-only")
            try repoData.write(to: newRepo)
            try prepare(newDir, newRepo)
            expect("リポジトリだけにある辞書をそのまま使える", try Data(contentsOf: newPersonal) == repoData, true)
            expect("元の辞書ファイルを移動しない", fm.fileExists(atPath: newRepo.path), true)

            let (recoverDir, absentRepo, recoveredPersonal) = try scenario("bundle-only")
            try prepare(recoverDir, absentRepo)
            expect("旧アプリだけに残る辞書を回収", try Data(contentsOf: recoveredPersonal) == Data(contentsOf: old), true)
            try Data("# 規則を消した\n".utf8).write(to: recoveredPersonal)
            try prepare(recoverDir, absentRepo)
            expect("回収した辞書の編集を再更新でも保持", try String(contentsOf: recoveredPersonal, encoding: .utf8), "# 規則を消した\n")

            let (bothDir, bothRepo, bothPersonal) = try scenario("personal-and-bundle")
            try personalData.write(to: bothPersonal)
            try prepare(bothDir, bothRepo)
            let legacy = try DictionaryStorage.legacyURLs(in: bothDir)
            expect("旧同梱辞書の独自語彙も保持", legacy.count, 1)
            expect("回収のため個人辞書を書き換えない", try Data(contentsOf: bothPersonal) == personalData, true)
            try Data("".utf8).write(to: legacy[0])
            try prepare(bothDir, bothRepo)
            expect("回収ファイルの削除を上書きしない", try Data(contentsOf: legacy[0]).count, 0)

            let (brokenDir, brokenRepo, brokenPersonal) = try scenario("broken-link")
            let missing = brokenDir.appendingPathComponent("missing.txt")
            try fm.createSymbolicLink(at: brokenPersonal, withDestinationURL: missing)
            do {
                try prepare(brokenDir, brokenRepo)
                expect("壊れたリンクでは更新を中止", false, true)
            } catch { expect("壊れたリンクでは更新を中止", true, true) }
            try DictionaryStorage.createIfMissing(Data("template".utf8), at: brokenPersonal)
            expect("壊れたリンクを雛形で置換しない", try fm.destinationOfSymbolicLink(atPath: brokenPersonal.path), missing.path)
            expect("壊れたリンクの先にも雛形を作らない", fm.fileExists(atPath: missing.path), false)

            let (emptyDir, emptyRepo, emptyPersonal) = try scenario("empty-personal")
            try Data().write(to: emptyPersonal)
            try prepare(emptyDir, emptyRepo)
            expect("意図的に空にした個人辞書を保持", try Data(contentsOf: emptyPersonal).count, 0)
            try DictionaryStorage.createIfMissing(Data("template".utf8), at: emptyPersonal)
            expect("空ファイルへ雛形を上書きしない", try Data(contentsOf: emptyPersonal).count, 0)

            let (corruptDir, corruptRepo, corruptPersonal) = try scenario("corrupt-config")
            try personalData.write(to: corruptPersonal)
            try Data("invalid".utf8).write(to: corruptDir.appendingPathComponent("dictionary-sources.json"))
            do {
                try prepare(corruptDir, corruptRepo)
                expect("壊れた移行記録を黙って初期化しない", false, true)
            } catch { expect("壊れた移行記録を黙って初期化しない", true, true) }
            expect("移行失敗でも辞書を保持", try Data(contentsOf: corruptPersonal) == personalData, true)
        } catch {
            expect("辞書引き継ぎテストが完了する", String(describing: error), "success")
        }
    }

    static func expect(_ name: String, _ actual: [URL], _ expected: [URL]) {
        expect(name, actual == expected, true)
    }

    static func indicatorPlacement() {
        let ax = CGRect(x: -1100, y: 120, width: 700, height: 160)
        let frame = IndicatorPlacement.appKitFrame(ax, primaryHeight: 900)
        expect("左の画面も座標変換できる", frame == CGRect(x: -1100, y: 620, width: 700, height: 160), true)
        let upper = IndicatorPlacement.appKitFrame(CGRect(x: 0, y: -500, width: 300, height: 100), primaryHeight: 900)
        expect("上の画面は正のAppKit座標になる", upper.minY == 1300, true)
        let size = CGSize(width: 222, height: 42)
        let visible = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let offset = CGPoint(x: 100, y: 180)
        expect("保存位置を保つ", IndicatorPlacement.origin(offset: offset, size: size, visible: visible) == offset, true)
        let second = CGRect(x: -1400, y: 100, width: 1200, height: 900)
        expect("別画面でも左下からの距離を保つ",
               IndicatorPlacement.origin(offset: offset, size: size, visible: second) == CGPoint(x: -1300, y: 280), true)
        let small = CGRect(x: 1000, y: 0, width: 600, height: 400)
        expect("小さい画面の外へ出ない", IndicatorPlacement.origin(offset: CGPoint(x: 900, y: 700), size: size, visible: small) == CGPoint(x: 1378, y: 358), true)
        expect("画面より目印が大きくても原点を保つ", IndicatorPlacement.origin(offset: offset, size: size, visible: CGRect(x: 0, y: 0, width: 100, height: 20)) == .zero, true)
    }

    static func dictationLifecycle() {
        var state = DictationLifecycle()
        let first = state.begin()!
        expect("準備中も停止を受け付ける", state.isActive, true)
        expect("準備中の二重開始を拒否", state.begin() == nil, true)
        expect("準備を取り消せる", state.stop() == first, true)
        expect("取り消した準備の結果を拒否", state.didStart(first), false)
        expect("停止処理中の二重停止を拒否", state.stop() == nil, true)
        expect("後始末中に次の収録を始めない", state.begin() == nil, true)
        state.didStop(first)
        let second = state.begin()!
        expect("古い収録結果を次に流さない", state.accepts(first), false)
        expect("新しい準備から収録へ進める", state.didStart(second), true)
        state.didStop(first)
        expect("古い後始末が新しい収録を止めない", state.isActive, true)
        expect("収録中の二重開始を拒否", state.begin() == nil, true)
        _ = state.stop()
        expect("停止操作の直後から結果を拒否", state.accepts(second), false)
        state.didStop(second)
        expect("停止完了後は再開可能", state.begin() != nil, true)
    }
}
