import SwiftUI
import AppKit

@MainActor
final class Controller: ObservableObject {

    static let shared = Controller()

    @Published private(set) var isRunning = false
    @Published private(set) var status = "待機中"

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

        // キーの見張りにも、文字の打ち込みにもアクセシビリティ権限が要る。
        // 無いまま起動すると ⌘ を長押ししても無反応で、原因が分からないまま終わる
        guard injector.requestAccessibilityIfNeeded(), trigger.start() else {
            status = "アクセシビリティの許可待ち"
            presentAccessibilityNotice()
            return
        }
        status = "待機中（⌘ 長押しで開始）"
    }

    /// 権限を与えたあとに呼び直すための入口
    func retryBootstrap() {
        guard trigger.start() else {
            presentAccessibilityNotice()
            return
        }
        status = "待機中（⌘ 長押しで開始）"
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

    private func presentAccessibilityNotice() {
        let alert = NSAlert()
        alert.messageText = "アクセシビリティの許可が必要です"
        alert.informativeText = """
        nobetsu は ⌘ の長押しを見張り、認識した文字を今使っているアプリへ直接打ち込みます。
        そのために「システム設定 > プライバシーとセキュリティ > アクセシビリティ」で
        nobetsu を許可してください。

        許可したら、メニューバーの波形アイコンから「権限を確認して再開」を選んでください。
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "システム設定を開く")
        alert.addButton(withTitle: "あとで")

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            NSWorkspace.shared.open(url)
        }
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
            Button(controller.isRunning ? "停止" : "話しはじめる") {
                controller.toggle()
            }
            Text(controller.status)

            Divider()

            Text("⌘ を長押しで開始")
            Text("もう一度 ⌘、または ESC で停止")

            Divider()

            Toggle("右の ⌘ だけで開始する", isOn: $controller.rightCommandOnly)
            Toggle("遠距離マイク補正", isOn: $controller.useFarField)
                .disabled(controller.isRunning)
            Toggle("認識中の文字を画面に表示", isOn: $controller.showsOverlay)

            Divider()

            Button("権限を確認して再開") { controller.retryBootstrap() }
            Button("nobetsu を終了") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: controller.isRunning ? "waveform.circle.fill" : "waveform")
        }
    }
}
