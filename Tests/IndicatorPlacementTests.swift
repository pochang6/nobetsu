import Foundation

extension Tests {
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
