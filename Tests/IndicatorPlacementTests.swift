import Foundation

extension Tests {
    static func indicatorScreenPreference() {
        let suite = "nobetsu-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        expect("画面固定の既定は自動", IndicatorScreenPreference.load(from: defaults) == nil, true)
        let upper = IndicatorScreenPreference(id: "upper-display", name: "上のモニター")
        IndicatorScreenPreference.save(upper, to: defaults)
        let restored = IndicatorScreenPreference.load(from: defaults)
        expect("固定先を再起動後も読み戻せる", restored == upper, true)
        let frames = [CGRect(x: 0, y: 0, width: 1000, height: 800),
                      CGRect(x: 0, y: 800, width: 1200, height: 1000),
                      CGRect(x: 1000, y: 0, width: 1200, height: 1000)]
        let input = CGRect(x: 20, y: 20, width: 100, height: 100)
        let ids = ["built-in", "upper-display", "right-display"]
        func selected(_ screens: [CGRect], _ ids: [String?], _ input: CGRect?) -> Int? {
            IndicatorPlacement.screenIndex(screens: screens, input: input, window: nil,
                preferredIndex: restored?.index(in: ids))
        }
        expect("入力欄と別の画面へ固定できる", selected(frames, ids, input) == 1, true)
        expect("入力欄が右へ移動しても固定先を保つ",
               selected(frames, ids, CGRect(x: 1200, y: 20, width: 100, height: 100)) == 1, true)
        expect("入力欄が見えなくても固定先を保つ", selected(frames, ids, nil) == 1, true)
        expect("接続順が変わっても同じモニターを選ぶ",
               selected([frames[2], frames[0], frames[1]], [ids[2], ids[0], ids[1]], input) == 2, true)
        expect("固定先を外した間は入力欄の画面へ戻す",
               selected([frames[0], frames[2]], [ids[0], ids[2]], input) == 0, true)
        expect("固定先の再接続でその画面に戻る", selected(frames, ids, input) == 1, true)
        expect("画面が1枚もなければ選ばない", selected([], [], input) == nil, true)
        IndicatorScreenPreference.save(nil, to: defaults)
        expect("固定解除は保存先からも削除", defaults.object(forKey: IndicatorScreenPreference.defaultsKey) == nil, true)
        expect("解除後は入力欄の画面を選ぶ",
               IndicatorPlacement.screenIndex(screens: frames, input: input, window: nil,
                preferredIndex: IndicatorScreenPreference.load(from: defaults)?.index(in: ids)) == 0, true)
        defaults.set(Data("invalid".utf8), forKey: IndicatorScreenPreference.defaultsKey)
        expect("保存設定が壊れていても自動選択できる", IndicatorScreenPreference.load(from: defaults) == nil, true)
    }

    static func indicatorScreenSelection() {
        let screens = [CGRect(x: 0, y: 0, width: 1512, height: 982),
                       CGRect(x: -408, y: 982, width: 1920, height: 1080),
                       CGRect(x: 1512, y: 475, width: 1920, height: 1080)]
        let input = IndicatorPlacement.appKitFrame(CGRect(x: 0, y: -4327, width: 752, height: 5309), primaryHeight: 982)
        let window = IndicatorPlacement.appKitFrame(CGRect(x: 0, y: 69, width: 1512, height: 913), primaryHeight: 982)
        func choose(_ name: String, _ frames: [CGRect], _ input: CGRect?, _ window: CGRect?, _ expected: Int?) {
            expect(name, IndicatorPlacement.screenIndex(screens: frames, input: input, window: window) == expected, true)
        }
        choose("iTerm2の実測値: 巨大な入力欄を上の画面へ誤配置しない", screens, input, window, 0)
        let rightWindow = CGRect(x: 1600, y: 500, width: 1000, height: 700)
        choose("3画面: 右へ移したウィンドウを選ぶ", screens,
               CGRect(x: 1600, y: -4000, width: 750, height: 5200), rightWindow, 2)
        let horizontal = [CGRect(x: 0, y: 0, width: 1000, height: 800),
                          CGRect(x: 1000, y: 0, width: 1600, height: 1000)]
        choose("左右の画面: 横に長い文書はウィンドウ内に制限", horizontal,
               CGRect(x: 0, y: 50, width: 2600, height: 700), CGRect(x: 0, y: 50, width: 900, height: 700), 0)
        choose("入力欄がなくてもウィンドウの画面を選ぶ", screens, nil, rightWindow, 2)
        choose("ウィンドウが取れなければ入力欄だけで選ぶ", screens, rightWindow, nil, 2)
        choose("共通部分がないときはウィンドウを優先", screens, rightWindow, window, 0)
        choose("共通部分の幅が0でもウィンドウを優先", screens,
               CGRect(x: window.maxX, y: 50, width: 100, height: 100), window, 0)
        choose("どの画面とも重ならなければ予備の選択へ", screens,
               CGRect(x: -9000, y: -9000, width: 100, height: 100), nil, nil)
        choose("対象が取れなければ予備の選択へ", screens, nil, nil, nil)
        choose("画面がなければ選ばない", [], input, window, nil)
        choose("nullの入力欄はウィンドウへ戻す", screens, .null, window, 0)
        choose("無限の入力欄はウィンドウへ戻す", screens, .infinite, window, 0)
        choose("複数画面にまたがるウィンドウでも入力欄のある方を選ぶ", horizontal,
               CGRect(x: 1100, y: 50, width: 100, height: 100), CGRect(x: 0, y: 50, width: 1300, height: 600), 1)
    }
}
