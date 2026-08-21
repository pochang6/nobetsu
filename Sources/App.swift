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
    @Published var showsOverlay = true {
        didSet { if !showsOverlay { overlay.hide() } else if isRunning { overlay.show() } }
    }
    /// ⌘ の誤発火が気になるとき用の逃げ道。右⌘ だけを開始キーにする
    @Published var rightCommandOnly = false {
        didSet { trigger.rightCommandOnly = rightCommandOnly }
    }

    private let engine = DictationEngine()
    private let injector = TextInjector()
    private let overlay = OverlayController()
    private let trigger = TriggerMonitor()
    private let coach = PermissionCoach()

    /// この収録で確定した分。表示窓のためだけに持つ
    private var committed = ""

    private init() {
        engine.delegate = self
        engine.useFarField = useFarField
    }

    // MARK: - 起動

    func bootstrap() {
        trigger.onStart = { [weak self] in self?.start() }
        trigger.onStop = { [weak self] in self?.stop() }
        trigger.rightCommandOnly = rightCommandOnly

        coach.onReady = { [weak self] in self?.activateTrigger() ?? false }

        if coach.presentIfNeeded() {
            activateTrigger()
        } else {
            needsPermission = true
            status = "許可の設定が必要です"
        }
    }

    /// キーの見張りを起動する。許可が無ければ失敗する
    @discardableResult
    private func activateTrigger() -> Bool {
        guard trigger.start() else {
            needsPermission = true
            status = "許可の設定が必要です"
            return false
        }
        needsPermission = false
        status = "待機中（⌘ 長押しで開始）"
        return true
    }

    /// メニューから案内をもう一度開く
    func showPermissionCoach() {
        coach.present()
    }

    // MARK: - 開始と停止

    func toggle() { isRunning ? stop() : start() }

    func start() {
        guard !isRunning else { return }
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
        if showsOverlay {
            overlay.update(committed: committed, volatile: text, status: status)
        }
    }

    func dictation(didFinalize text: String) {
        injector.finalize(text)
        committed += text
        if showsOverlay {
            overlay.update(committed: committed, volatile: "", status: status)
        }
    }

    func dictation(didChangeRunning running: Bool, message: String) {
        isRunning = running
        status = message
        trigger.isRunning = running

        if running {
            if showsOverlay { overlay.show() }
        } else {
            overlay.update(committed: committed, volatile: "", status: message)
            // すぐ消すと最後の一言を読めないまま消える
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self, !self.isRunning else { return }
                self.overlay.hide()
            }
        }
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
                Button("⚠︎ アクセシビリティを許可する") {
                    controller.showPermissionCoach()
                }
                Text("許可するまで ⌘ の長押しに反応しません")
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

            Toggle("右の ⌘ だけで開始する", isOn: $controller.rightCommandOnly)
            Toggle("遠距離マイク補正", isOn: $controller.useFarField)
                .disabled(controller.isRunning)
            Toggle("認識中の文字を画面に表示", isOn: $controller.showsOverlay)

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
