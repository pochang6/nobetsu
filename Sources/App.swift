import SwiftUI
import AppKit

@MainActor
final class Controller: ObservableObject {

    static let shared = Controller()

    @Published private(set) var isRunning = false
    @Published private(set) var status = "待機中"
    /// 許可が足りていない。メニューバーのアイコンに警告を出すために持つ
    @Published private(set) var needsPermission = true

    @Published var useFarField = true {
        didSet { engine.useFarField = useFarField }
    }
    /// 認識中の文字を画面に流す。見た目は楽しいが入力先の文章と重なるので既定は切る
    @Published var showsTranscript = false {
        didSet {
            Defaults.showsTranscript = showsTranscript
            if !showsTranscript { overlay.hide() } else if isRunning { overlay.show() }
        }
    }
    @Published var showsIndicator = true {
        didSet {
            Defaults.showsIndicator = showsIndicator
            if !showsIndicator { indicator.hide() } else if isRunning { indicator.show() }
        }
    }
    @Published var soundEnabled = true {
        didSet { Sounds.enabled = soundEnabled }
    }
    @Published var launchAtLogin = false {
        didSet { LoginItem.setEnabled(launchAtLogin) }
    }
    /// ⌘ の誤発火が気になるとき用の逃げ道。右⌘ だけを開始キーにする
    @Published var rightCommandOnly = false {
        didSet { trigger.rightCommandOnly = rightCommandOnly }
    }
    /// 入力先から離れたら止める。
    ///
    /// 既定は有効。始めたことを忘れたまま別のアプリへ移り、
    /// 独り言が同僚宛の入力欄へ流れ込む事故を防ぐ。
    /// 一日中つけっぱなしにして、あちこちで喋りたい人は切ってよい
    @Published var stopsWhenFocusLeaves = true {
        didSet {
            Defaults.stopsWhenFocusLeaves = stopsWhenFocusLeaves
            // 見張り自体は設定に関わらず動かす。
            // 止めない設定でも、**カーソルが先頭へ戻されたのを直す**ために目は要る
        }
    }

    private let engine = DictationEngine()
    private let injector = TextInjector()
    private let overlay = OverlayController()
    private let indicator = IndicatorController()
    private let trigger = TriggerMonitor()
    private let focusWatcher = FocusWatcher()
    private let phrases = PhraseBook.shared

    private var permissionPoll: Timer?
    /// 許可の要求は一度きり。繰り返し呼んでもダイアログは出ないので無駄打ちしない
    private var didAskInputMonitoring = false
    private var didAskAccessibility = false
    /// 同じ失敗理由でログを埋めないための直前の記録
    private var lastFailureLog = ""
    /// 一時停止のときは目印を残す。× や ESC で止めたときは閉じる
    private var keepIndicatorVisible = false

    /// この収録で確定した分。表示窓のためだけに持つ
    private var committed = ""

    /// 自動で止まった理由。次に始めるまでメニューに残す
    private var autoStopReason: String?

    private init() {
        engine.delegate = self
        showsTranscript = Defaults.showsTranscript
        showsIndicator = Defaults.showsIndicator
        stopsWhenFocusLeaves = Defaults.stopsWhenFocusLeaves
        soundEnabled = Sounds.enabled
        engine.useFarField = useFarField
        engine.levelHandler = { [weak self] level in
            self?.indicator.update(level: level)
        }
        injector.didInject = { [weak self] in self?.indicator.didInjectText() }
        indicator.onPause = { [weak self] in self?.pause() }
        indicator.onResume = { [weak self] in self?.start() }
        indicator.onClose = { [weak self] in self?.stop() }
        indicator.menuProvider = { [weak self] in self?.buildIndicatorMenu() ?? NSMenu() }
        focusWatcher.onLeave = { [weak self] reason in
            guard let self else { return }
            guard self.stopsWhenFocusLeaves else {
                // 止めない設定。打ち込み位置の基準だけ捨てて、新しい入力先を見張り直す。
                // 見張りを降ろしてしまうと、戻ってきたときにカーソルの面倒を見る者がいなくなる
                Log.write("focus: \(reason)（止めない設定なので続ける）")
                self.injector.userTookOver()
                self.focusWatcher.retarget()
                return
            }
            self.stopBecauseFocusLeft(reason)
        }
        focusWatcher.onMovedWithinApp = { [weak self] in self?.injector.userTookOver() }
    }

    // MARK: - 起動

    func bootstrap() {
        Log.startSession()
        // アクセシビリティの判定より先に入力監視を扱う。
        // AXIsProcessTrusted() を先に呼ぶと入力監視の要求が通らなくなる既知の不具合がある
        Log.write("bootstrap: v\(NobetsuApp.version) / 入力監視 \(Permissions.inputMonitoringStatusText) / 署名 \(Permissions.signingSummary)")

        LoginItem.applyDefaultOnFirstLaunch()
        launchAtLogin = LoginItem.isEnabled

        trigger.onStart = { [weak self] in self?.start() }
        trigger.onStop = { [weak self] in self?.stop() }
        trigger.onUserTookOver = { [weak self] in self?.injector.userTookOver() }
        trigger.onUserSubmitted = { [weak self] in
            guard let self else { return }
            self.injector.userSubmitted()
            self.engine.cutSpan()
        }
        trigger.rightCommandOnly = rightCommandOnly

        if activateTrigger() { return }
        requestPermissions()
    }

    /// キーの見張りを起動する。許可が無ければ失敗する
    @discardableResult
    private func activateTrigger() -> Bool {
        guard trigger.start() else {
            // 失敗の理由は必ず残す。ただし同じ内容でログを埋めない
            let reason = "trigger: イベントタップを作れない（入力監視=\(Permissions.inputMonitoringGranted) アクセシビリティ=\(Permissions.accessibilityGranted)）"
            if reason != lastFailureLog {
                lastFailureLog = reason
                Log.write(reason)
            }
            needsPermission = true
            status = "許可が必要です"
            return false
        }
        lastFailureLog = ""
        Log.write("trigger: 見張りを開始した")
        needsPermission = false
        status = "待機中（⌘ 長押しで開始）"
        permissionPoll?.invalidate()
        permissionPoll = nil
        return true
    }

    /// 許可を求める。
    ///
    /// キーを飲み込めるタップ（.defaultTap）は、入力監視だけでなく
    /// **アクセシビリティも要求する**。つまり ⌘ の長押しを検知する前に両方が要る。
    /// 「アクセシビリティは文字を打つときに聞けばいい」という分け方は成立しない。
    ///
    /// 順番は必ず 入力監視 → アクセシビリティ。
    /// AXIsProcessTrusted() を先に呼ぶと入力監視の要求が通らなくなる既知の不具合があるため、
    /// 入力監視が片付くまでアクセシビリティには触れない。
    /// 一度に1つずつしか出ないので、何を聞かれているかも分かりやすい。
    func requestPermissions() {
        if activateTrigger() { return }

        // TCC のダイアログは、要求元が前面にいないと出ないことがある
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.askNextPermission()
        }
        startPermissionPoll()
    }

    /// 足りていない許可を1つだけ求める
    private func askNextPermission() {
        if !Permissions.inputMonitoringGranted {
            guard !didAskInputMonitoring else { return }
            didAskInputMonitoring = true
            Log.write("入力監視を求める: 要求前 \(Permissions.inputMonitoringStatusText)")
            let result = Permissions.promptForInputMonitoring()
            Log.write("入力監視を求めた: 戻り値=\(result) 要求後 \(Permissions.inputMonitoringStatusText)")
            return
        }

        if !Permissions.accessibilityGranted {
            guard !didAskAccessibility else { return }
            didAskAccessibility = true
            Log.write("アクセシビリティを求める")
            Permissions.promptForAccessibility()
        }
    }

    private func startPermissionPoll() {
        permissionPoll?.invalidate()
        permissionPoll = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.activateTrigger() { return }
                self.askNextPermission()
            }
        }
    }

    // MARK: - 開始と停止

    func toggle() { isRunning ? stop() : start() }

    func start() {
        guard !isRunning else { return }

        // 文字を打ち込むにはアクセシビリティが要る。無いまま始めると
        // 認識はできているのに何も入らない、という一番わけの分からない状態になる。
        // 「使おうとした瞬間」である今、OS の許可ダイアログを出す
        guard Permissions.accessibilityGranted else {
            Log.write("start: アクセシビリティ未許可のため中断し、許可を求める")
            status = "文字を入力する許可が必要です"
            Sounds.playFailure()
            Permissions.promptForAccessibility()
            return
        }

        committed = ""
        autoStopReason = nil
        // 辞書は「喋りはじめる瞬間」に読む。書き換えたら、次のひと言から効く
        phrases.reloadIfNeeded()
        injector.beginSession()
        focusWatcher.start()
        engine.start()
    }

    /// 目印の「…」から開く小さな設定。よく触るものだけを置く。
    /// 全部の設定はメニューバー側にある
    private func buildIndicatorMenu() -> NSMenu {
        let menu = NSMenu()

        // 設定が先、やめる操作は最後。
        //
        // 以前はここの先頭に「閉じる」を置いていたが、
        // **このメニューを閉じるボタンだと読まれて、音声入力ごと止まって驚かせた。**
        // メニュー自体は ESC やメニューの外を押せば閉じる（macOS の作法）ので、
        // そのための項目は要らない。
        // 何が起きるかを言い切る文言にして、位置も下（終了操作の定位置）へ移した

        let sound = menu.addItem(withTitle: "開始と終了を音で知らせる",
                                 action: #selector(menuToggleSound), keyEquivalent: "")
        sound.target = self
        sound.state = soundEnabled ? .on : .off

        let transcript = menu.addItem(withTitle: "認識中の文字を画面に流す",
                                      action: #selector(menuToggleTranscript), keyEquivalent: "")
        transcript.target = self
        transcript.state = showsTranscript ? .on : .off

        let focus = menu.addItem(withTitle: "入力先から離れたら止める",
                                 action: #selector(menuToggleFocusStop), keyEquivalent: "")
        focus.target = self
        focus.state = stopsWhenFocusLeaves ? .on : .off

        menu.addItem(.separator())

        menu.addItem(withTitle: "辞書を編集する",
                     action: #selector(menuEditDictionary), keyEquivalent: "")
            .target = self

        menu.addItem(withTitle: "この目印の位置を初期状態に戻す",
                     action: #selector(menuResetPosition), keyEquivalent: "")
            .target = self

        menu.addItem(.separator())

        let stopItem = menu.addItem(withTitle: "音声入力を止める（ESC）",
                                    action: #selector(menuStop), keyEquivalent: "")
        stopItem.target = self
        stopItem.image = NSImage(systemSymbolName: "stop.fill",
                                 accessibilityDescription: "音声入力を止める")

        return menu
    }

    @objc private func menuStop() { stop() }
    @objc private func menuToggleSound() { soundEnabled.toggle() }
    @objc private func menuToggleTranscript() { showsTranscript.toggle() }
    @objc private func menuToggleFocusStop() { stopsWhenFocusLeaves.toggle() }
    @objc private func menuEditDictionary() { editDictionary() }
    @objc private func menuResetPosition() { indicator.resetPosition() }

    /// 個人辞書を開く。無ければ書き方の分かる雛形を作ってから開く
    func editDictionary() {
        phrases.openPersonalFile()
    }

    /// 辞書を読み直す。喋りはじめるたびに自動で読むので、普段は使わなくてよい
    func reloadDictionary() {
        phrases.reload()
    }

    /// 認識をやめて、目印も閉じる。ESC・⌘・× のときの動き
    func stop() {
        keepIndicatorVisible = false
        halt()
        indicator.hide()
    }

    /// 入力先から離れたので、こちらの判断で止めた。
    ///
    /// **押していないのに終わる**ので、普段の終了音と同じでは何が起きたのか分からない。
    /// 音を変えて、止まった理由もメニューに残す
    private func stopBecauseFocusLeft(_ reason: String) {
        guard isRunning else { return }
        autoStopReason = reason
        keepIndicatorVisible = false
        halt(auto: true)
        indicator.hide()
    }

    /// 認識だけやめる。目印は残り、そのまま再開できる。
    /// 一時停止のつもりで押したのに目印ごと消えると、どこへ行ったのか分からなくなる
    func pause() {
        keepIndicatorVisible = true
        halt()
        indicator.setRunning(false)
    }

    private func halt(auto: Bool = false) {
        focusWatcher.stop()
        guard isRunning else { return }
        // 止める操作をした「今」鳴らす。後始末を待つと、止めたのに無反応な時間が生まれる
        if auto { Sounds.playAutoStop() } else { Sounds.playStop() }
        // 先に門を閉じる。停止後に遅れて届く確定結果を打ち込むと二重入力になる
        injector.endSession()
        engine.stop()
    }
}

// MARK: - 認識結果の受け取り

extension Controller: DictationDelegate {

    func dictation(didUpdateVolatile text: String) {
        // 打つ直前に言い換える。表示も同じ文字にしないと、目で見たものと入った文字がずれる
        let fixed = phrases.apply(to: text)
        injector.updateVolatile(fixed)
        if showsTranscript {
            overlay.update(committed: committed, volatile: fixed, status: status)
        }
    }

    func dictation(didFinalize text: String) {
        let fixed = phrases.apply(to: text)
        injector.finalize(fixed)
        committed += fixed
        if showsTranscript {
            overlay.update(committed: committed, volatile: "", status: status)
        }
    }

    func dictationDidBeginCapturing() {
        // ここが「もう聞いています」の合図。この音を聞いてから喋れば、頭は削られない
        Sounds.playStart()
    }

    func dictation(didChangeRunning running: Bool, message: String) {
        isRunning = running
        // なぜ止まったのかは、押していない停止のときこそ知りたい
        if !running, let reason = autoStopReason {
            status = "\(reason)ので止めました"
        } else {
            status = message
        }
        // 一時停止して目印が残っている間も ESC で閉じられるようにしておく。
        // × を押すしかない状態にすると、キーボードから抜け出せなくなる
        trigger.isRunning = running || keepIndicatorVisible

        if running {
            if showsIndicator {
                indicator.setRunning(true)
                indicator.show()
            }
            if showsTranscript { overlay.show() }
        } else {
            // 停止音は halt() の時点で鳴らし終えている。ここで鳴らすと二重になるうえ遅い
            indicator.setRunning(false)
            if !keepIndicatorVisible { indicator.hide() }
            if showsTranscript {
                overlay.update(committed: committed, volatile: "", status: message)
                // すぐ消すと最後の一言を読めないまま消える
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                    guard let self, !self.isRunning else { return }
                    self.overlay.hide()
                }
            }
        }
    }
}

/// 設定の保存先。数が少ないので UserDefaults で足りる
enum Defaults {
    static var showsTranscript: Bool {
        get { UserDefaults.standard.bool(forKey: "nobetsu.showsTranscript") }
        set { UserDefaults.standard.set(newValue, forKey: "nobetsu.showsTranscript") }
    }
    /// 目印を動かした位置。**画面の左下からの距離**で覚える。
    /// 絶対の座標で覚えると、モニターを繋ぎ替えたときや、
    /// 前回と違う画面で喋ったときに、見当違いの場所や画面の外へ出てしまう
    static var indicatorOffset: NSPoint? {
        get {
            let d = UserDefaults.standard
            guard d.object(forKey: "nobetsu.indicatorDX") != nil else { return nil }
            return NSPoint(x: d.double(forKey: "nobetsu.indicatorDX"),
                           y: d.double(forKey: "nobetsu.indicatorDY"))
        }
        set {
            let d = UserDefaults.standard
            guard let newValue else {
                d.removeObject(forKey: "nobetsu.indicatorDX")
                d.removeObject(forKey: "nobetsu.indicatorDY")
                return
            }
            d.set(newValue.x, forKey: "nobetsu.indicatorDX")
            d.set(newValue.y, forKey: "nobetsu.indicatorDY")
        }
    }

    /// 入力先から離れたら止める。既定は有効（事故を防ぐ側に倒す）
    static var stopsWhenFocusLeaves: Bool {
        get {
            if UserDefaults.standard.object(forKey: "nobetsu.stopsWhenFocusLeaves") == nil { return true }
            return UserDefaults.standard.bool(forKey: "nobetsu.stopsWhenFocusLeaves")
        }
        set { UserDefaults.standard.set(newValue, forKey: "nobetsu.stopsWhenFocusLeaves") }
    }

    static var showsIndicator: Bool {
        get {
            if UserDefaults.standard.object(forKey: "nobetsu.showsIndicator") == nil { return true }
            return UserDefaults.standard.bool(forKey: "nobetsu.showsIndicator")
        }
        set { UserDefaults.standard.set(newValue, forKey: "nobetsu.showsIndicator") }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Controller.shared.bootstrap()
    }
}

@main
struct NobetsuApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var controller = Controller.shared

    var body: some Scene {
        MenuBarExtra {
            if controller.needsPermission {
                // 救済措置。ダイアログを閉じてしまった人がここからやり直せる
                Button("入力監視を許可する") { controller.requestPermissions() }
                Button("入力監視の設定を開く") { Permissions.openInputMonitoringSettings() }
                Divider()
                Text("許可されるまで ⌘ の長押しに反応しません")
                Divider()
            } else {
                Button(controller.isRunning ? "停止" : "話しはじめる") {
                    controller.toggle()
                }
                Text(controller.status)
                Divider()
                Text("⌘ を長押しで開始")
                Text("もう一度 ⌘、または ESC で停止")
                Divider()
            }

            Toggle("ログイン時に起動", isOn: $controller.launchAtLogin)
            Toggle("開始と終了を音で知らせる", isOn: $controller.soundEnabled)
            Toggle("左上に認識中の目印を出す", isOn: $controller.showsIndicator)
            Toggle("認識中の文字を画面に流す", isOn: $controller.showsTranscript)
            Toggle("右の ⌘ だけで開始する", isOn: $controller.rightCommandOnly)
            Toggle("入力先から離れたら止める", isOn: $controller.stopsWhenFocusLeaves)
            Toggle("遠距離マイク補正", isOn: $controller.useFarField)
                .disabled(controller.isRunning)

            Divider()

            Button("辞書を編集する") { controller.editDictionary() }
            Button("辞書を読み直す") { controller.reloadDictionary() }

            Divider()

            // 利用者がバージョンを確かめられる唯一の場所。
            // 不具合の報告をもらうときに「どれを使っているか」が分からないと話が始まらない
            Text("nobetsu \(NobetsuApp.version)")

            Button("nobetsu を終了") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: iconName)
        }
    }

    /// Info.plist に焼き込まれた値。元は VERSION ファイル1枚
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    private var iconName: String {
        if controller.needsPermission { return "exclamationmark.triangle.fill" }
        return controller.isRunning ? "waveform.circle.fill" : "waveform"
    }
}
