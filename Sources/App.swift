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

    private let engine = DictationEngine()
    private let injector = TextInjector()
    private let overlay = OverlayController()
    private let indicator = IndicatorController()
    private let trigger = TriggerMonitor()

    private var permissionPoll: Timer?

    /// この収録で確定した分。表示窓のためだけに持つ
    private var committed = ""

    private init() {
        engine.delegate = self
        showsTranscript = Defaults.showsTranscript
        showsIndicator = Defaults.showsIndicator
        soundEnabled = Sounds.enabled
        engine.useFarField = useFarField
        engine.levelHandler = { [weak self] level in
            self?.indicator.update(level: level)
        }
        indicator.onClick = { [weak self] in self?.stop() }
    }

    // MARK: - 起動

    func bootstrap() {
        Log.startSession()
        // アクセシビリティの判定より先に入力監視を扱う。
        // AXIsProcessTrusted() を先に呼ぶと入力監視の要求が通らなくなる既知の不具合がある
        Log.write("bootstrap: 入力監視 \(Permissions.inputMonitoringStatusText) / 署名 \(Permissions.signingSummary)")

        LoginItem.applyDefaultOnFirstLaunch()
        launchAtLogin = LoginItem.isEnabled

        trigger.onStart = { [weak self] in self?.start() }
        trigger.onStop = { [weak self] in self?.stop() }
        trigger.rightCommandOnly = rightCommandOnly

        if activateTrigger() { return }
        requestPermissions()
    }

    /// キーの見張りを起動する。許可が無ければ失敗する
    @discardableResult
    private func activateTrigger() -> Bool {
        guard trigger.start() else {
            if !needsPermission {
                Log.write("trigger: イベントタップを作れない（入力監視=\(Permissions.inputMonitoringGranted)）")
            }
            needsPermission = true
            status = "許可が必要です"
            return false
        }
        Log.write("trigger: 見張りを開始した")
        needsPermission = false
        status = "待機中（⌘ 長押しで開始）"
        permissionPoll?.invalidate()
        permissionPoll = nil
        return true
    }

    /// 入力監視の許可を求める。
    ///
    /// 許可ダイアログを出すのは CGRequestListenEventAccess であって、
    /// CGEventTap の生成ではない。tapCreate は許可が無ければ黙って nil を返すだけ。
    ///
    /// 2つの許可を並べて聞かない。必要になる瞬間が違うからだ。
    /// 入力監視は ⌘ の長押しを待ち受けるために起動した時点で要る。
    /// アクセシビリティは文字を打ち込むときに要るので、初めて喋ろうとしたときに聞く。
    func requestPermissions() {
        if activateTrigger() { return }

        if !Permissions.inputMonitoringGranted {
            // TCC のダイアログは、要求元が前面にいないと出ないことがある
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                Log.write("入力監視: 要求前 \(Permissions.inputMonitoringStatusText)")
                let result = Permissions.promptForInputMonitoring()
                Log.write("入力監視: CGRequestListenEventAccess=\(result) 要求後 \(Permissions.inputMonitoringStatusText)")
            }
        }
        startPermissionPoll()
    }

    private func startPermissionPoll() {
        permissionPoll?.invalidate()
        permissionPoll = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard Permissions.inputMonitoringGranted else { return }
                self?.activateTrigger()
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
        injector.reset()
        engine.start()
    }

    func stop() {
        guard isRunning else { return }
        engine.stop()
        injector.reset()
    }
}

// MARK: - 認識結果の受け取り

extension Controller: DictationDelegate {

    func dictation(didUpdateVolatile text: String) {
        injector.updateVolatile(text)
        if showsTranscript {
            overlay.update(committed: committed, volatile: text, status: status)
        }
    }

    func dictation(didFinalize text: String) {
        injector.finalize(text)
        committed += text
        if showsTranscript {
            overlay.update(committed: committed, volatile: "", status: status)
        }
    }

    func dictation(didChangeRunning running: Bool, message: String) {
        let wasRunning = isRunning
        isRunning = running
        status = message
        trigger.isRunning = running

        if running {
            if !wasRunning { Sounds.playStart() }
            if showsIndicator { indicator.show() }
            if showsTranscript { overlay.show() }
        } else {
            if wasRunning { Sounds.playStop() }
            indicator.hide()
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
            Toggle("遠距離マイク補正", isOn: $controller.useFarField)
                .disabled(controller.isRunning)

            Divider()

            Button("nobetsu を終了") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: iconName)
        }
    }

    private var iconName: String {
        if controller.needsPermission { return "exclamationmark.triangle.fill" }
        return controller.isRunning ? "waveform.circle.fill" : "waveform"
    }
}
