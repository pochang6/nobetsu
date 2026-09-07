import AppKit
import SwiftUI
import ColorSync

/// 認識中であることを知らせる小さな目印。
///
/// 文字を大きく流す窓は、見た目は気持ちいいが入力先の文章と重なって邪魔になる。
/// かといって画面の隅すぎると気づけない。
/// 初期位置は「左から約1/3、下から約2/5の高さ」に置く。
/// 入力欄は画面の下寄り・左寄りにあることが多く、その少し上に浮く格好になる。
///
/// ただし最適な位置は人と作業によって違うので、**ドラッグで動かせる**ようにし、
/// 動かした位置は覚えておく。出るときも消えるときも、ふわりと。
@MainActor
final class IndicatorController {

    /// 停止ボタン。目印は残したまま、認識だけ止める
    var onPause: (() -> Void)?
    /// 再開ボタン
    var onResume: (() -> Void)?
    /// × ボタン。認識を止めて目印も閉じる
    var onClose: (() -> Void)?
    /// 設定メニューを組み立てる
    var menuProvider: (() -> NSMenu)?

    /// 認識中かどうか。止めても目印は消えず、見た目だけ変わる
    func setRunning(_ running: Bool) {
        model.isRunning = running
    }

    private var panel: NonActivatingPanel?
    private let model = IndicatorModel()
    private var moveObserver: NSObjectProtocol?
    private var cursorKeeper: Timer?
    private var spaceObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var wantsVisible = false
    private var visibilityGeneration: UInt64 = 0
    private var isPositioning = false
    private var inputFrame: CGRect?
    private var targetWindowFrame: CGRect?
    private var lastScreenNumber: NSNumber?
    private var spaceGeneration: UInt64 = 0
    /// 直近に文字を打ち込んだ時刻。カーソルが隠されるのはこの直後だけ
    private var lastInjectAt = Date.distantPast
    private var lastNudgeAt = Date.distantPast

    private static let size = NSSize(width: 222, height: 42)

    func show() {
        wantsVisible = true
        visibilityGeneration &+= 1
        if panel == nil { build() }
        guard let panel else { return }

        reposition()
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }

        startCursorKeeper()
    }

    /// 音声入力の間、マウスカーソルを消させない。
    ///
    /// macOS はキー入力中にマウスカーソルを隠す。nobetsu は文字を打ち込み続けるので、
    /// その仕様が延々と発動し、押そうと近づいた瞬間に消える・動かすと出る、を繰り返す
    private func startCursorKeeper() {
        cursorKeeper?.invalidate()
        cursorKeeper = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.keepCursorVisible() }
        }
    }

    /// 打ち込んだ直後に呼ばれる
    func didInjectText() {
        lastInjectAt = Date()
        keepCursorVisible()
    }

    /// **音声入力中は、マウスカーソルを消させない。**
    ///
    /// はじめは目印の上にいるときだけ出し直していたが、それでは足りなかった。
    /// 喋りながら画面を見て、スクロールしたり動画を選んだりする使い方では、
    /// カーソルは画面のどこにでもいる。打つたびに消えて、動かすと出る、を繰り返すと
    /// ちらついて目障りなだけでなく、いまどこを指しているのか分からなくなる。
    ///
    /// 打ち込みが続いている間だけに絞る。打っていなければ、誰も隠さない
    func keepCursorVisible() {
        guard let panel, panel.isVisible else { return }

        NSCursor.setHiddenUntilMouseMoves(false)
        NSCursor.unhide()

        guard Date().timeIntervalSince(lastInjectAt) < 0.6 else { return }
        guard Date().timeIntervalSince(lastNudgeAt) > 0.05 else { return }
        lastNudgeAt = Date()
        nudgeCursor()
    }

    /// カーソルを 1 ピクセルだけ動かして、戻す。
    ///
    /// `NSCursor.unhide()` では出てこない。**隠しているのは相手のアプリだから。**
    /// macOS は文字が打たれるとカーソルを隠す。隠すのは打ち込み先のアプリであって、
    /// こちらではない。別のプロセスが隠したものを、こちらから出すことはできない。
    ///
    /// ただし macOS は「マウスが**動いたら**出す」。
    /// はじめは同じ位置へ動いたことにしてみたが、それでは出てこなかった。
    /// 動いていないものは動いたことにならない。
    /// そこで、画面の外へ出ない向きへ 1 ピクセルだけ動かして、すぐ戻す。
    /// 最終的な位置は変わらないので、利用者には分からない。
    ///
    /// 打ち込みが続いている間だけに絞る。常に流すと、目印を掴んで動かしている最中にも
    /// 割り込むことになる
    private func nudgeCursor() {
        guard let primary = NSScreen.screens.first else { return }
        let location = NSEvent.mouseLocation
        // 画面の外へ出ない向きへ 1 ピクセル。戻すので最終位置は変わらない
        let step: CGFloat = location.x <= primary.frame.midX ? 1 : -1

        // NSEvent は左下が原点、CGEvent は左上が原点
        let y = primary.frame.maxY - location.y
        moveCursor(to: CGPoint(x: location.x + step, y: y))
        moveCursor(to: CGPoint(x: location.x, y: y))
    }

    private func moveCursor(to point: CGPoint) {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let move = CGEvent(mouseEventSource: source,
                                 mouseType: .mouseMoved,
                                 mouseCursorPosition: point,
                                 mouseButton: .left)
        else { return }

        // 自分が出したものだと分かるようにしておく（見張りが拾わないように）
        move.setIntegerValueField(.eventSourceUserData, value: TriggerMonitor.injectedMagic)
        move.post(tap: .cgAnnotatedSessionEventTap)
    }

    func hide() {
        wantsVisible = false
        visibilityGeneration &+= 1
        let token = visibilityGeneration
        // 消える前に、隠れたままのカーソルを出しておく。
        // 打ち込みが終わってから出し直す機会は、もう無い
        if let panel, panel.isVisible { nudgeCursor() }

        // 目印が消えたら見張りも止める。
        // 消したのに 25Hz のタイマーが回り続けると、何もしていない間もメインスレッドを刻む。
        // ここはキーの見張り（イベントタップ）と同じスレッドなので、
        // 混み合うとタップごと OS に無効化され、キー入力が効かなくなる
        cursorKeeper?.invalidate()
        cursorKeeper = nil

        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, !self.wantsVisible, self.visibilityGeneration == token else { return }
                panel.orderOut(nil)
            }
        }
    }

    func update(level: Float) {
        model.level = level
    }

    /// 置き場所を初期位置に戻す
    func resetPosition() {
        Defaults.indicatorOffset = nil
        reposition()
    }

    private let preferences: UserDefaults
    private(set) var fixedScreen: IndicatorScreenPreference?

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        self.fixedScreen = IndicatorScreenPreference.load(from: preferences)
    }

    private static func screenID(_ screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue(),
              let string = CFUUIDCreateString(nil, uuid) else { return nil }
        return string as String
    }

    var screenChoices: [IndicatorScreenPreference] {
        NSScreen.screens.compactMap { screen in
            Self.screenID(screen).map { IndicatorScreenPreference(id: $0, name: screen.localizedName) }
        }
    }

    var canPinCurrentScreen: Bool {
        guard let panel, panel.isVisible, let screen = panel.screen else { return false }
        return Self.screenID(screen) != nil
    }

    func pinCurrentScreen() {
        guard let screen = panel?.screen, let id = Self.screenID(screen) else { return }
        pinScreen(id: id)
    }

    func pinScreen(id: String) {
        // メニューを開いた後に外された画面は固定しない。
        guard let choice = screenChoices.first(where: { $0.id == id }) else { return }
        fixedScreen = choice
        IndicatorScreenPreference.save(choice, to: preferences)
        reposition()
        Log.write("indicator: 表示する画面を固定した")
    }

    func useAutomaticScreen() {
        fixedScreen = nil
        IndicatorScreenPreference.save(nil, to: preferences)
        lastScreenNumber = nil
        reposition()
        Log.write("indicator: 表示する画面の固定を解除した")
    }

    // MARK: - 組み立て

    private func build() {
        let p = NonActivatingPanel(
            contentRect: NSRect(origin: .zero, size: IndicatorController.size),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false)

        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        // 背景をつかんで動かせるようにする。ボタンの上以外はどこでも掴める
        p.isMovable = true
        p.isMovableByWindowBackground = true

        let view = IndicatorView(
            model: model,
            onPause: { [weak self] in self?.onPause?() },
            onResume: { [weak self] in self?.onResume?() },
            onClose: { [weak self] in self?.onClose?() },
            onMenu: { [weak self] in self?.showMenu() })

        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: IndicatorController.size)
        host.autoresizingMask = [.width, .height]
        p.contentView = host

        // 動かした場所を覚える。毎回同じところに出ないと落ち着かない
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: p, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, !self.isPositioning, NSEvent.pressedMouseButtons != 0,
                      let moved = note.object as? NSWindow,
                      let screen = moved.screen else { return }
                Defaults.indicatorOffset = CGPoint(x: moved.frame.minX - screen.visibleFrame.minX,
                                                  y: moved.frame.minY - screen.visibleFrame.minY)
            }
        }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshSpace() }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshSpace() }
        }

        panel = p
    }

    private func showMenu() {
        guard let menu = menuProvider?(), let contentView = panel?.contentView else { return }
        let point = NSPoint(x: IndicatorController.size.width - 26, y: 4)
        menu.popUp(positioning: nil, at: point, in: contentView)
    }

    // MARK: - 位置

    /// いま作業している画面。
    ///
    /// **メインディスプレイに出してはいけない。**
    /// サブモニターで喋っているのに、目印だけメインに出ては誰も気づけない。
    /// `NSScreen.main` は「自分のキーウィンドウがある画面」なので、
    /// キーウィンドウを持たないこのアプリでは常にメインを指してしまう。
    ///
    /// 入力欄をウィンドウ内に切り詰め、重なりが最大の画面を選ぶ。
    /// 情報が欠けた間は直前の画面、初回はマウスのいる画面を使う。
    private func currentScreen() -> NSScreen? {
        let screens = NSScreen.screens
        // 固定先が未接続なら自動選択。設定は消さず、再接続したら同じモニターへ戻る。
        let preferred = fixedScreen?.index(in: screens.map(Self.screenID))
        if let index = IndicatorPlacement.screenIndex(screens: screens.map(\.frame),
                                                       input: inputFrame, window: targetWindowFrame,
                                                       preferredIndex: preferred) {
            let screen = screens[index]
            lastScreenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            return screen
        }
        // AX の一時的な欠落でマウス側の画面へ飛ばない。
        if let lastScreenNumber, let screen = NSScreen.screens.first(where: {
            $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber == lastScreenNumber
        }) { return screen }
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.screens.first
    }

    func follow(inputAXFrame: CGRect?, windowAXFrame: CGRect?) {
        guard let primary = NSScreen.screens.first else { return }
        let input = inputAXFrame.map { IndicatorPlacement.appKitFrame($0, primaryHeight: primary.frame.height) }
        let window = windowAXFrame.map { IndicatorPlacement.appKitFrame($0, primaryHeight: primary.frame.height) }
        let changed = input != inputFrame || window != targetWindowFrame
        inputFrame = input
        targetWindowFrame = window
        guard wantsVisible else { return }
        reposition()
        if changed || panel?.isOnActiveSpace == false { panel?.orderFrontRegardless() }
    }

    private func reposition() {
        guard let panel, NSEvent.pressedMouseButtons == 0 else { return }
        isPositioning = true
        defer { isPositioning = false }
        panel.setFrameOrigin(savedOrigin(for: panel))
    }

    private func refreshSpace() {
        guard wantsVisible else { return }
        spaceGeneration &+= 1
        let token = spaceGeneration
        // Space の通知は遷移開始時に来ることがある。遷移後にも前面へ戻す。
        for delay in [0.15, 0.55] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.wantsVisible, self.spaceGeneration == token else { return }
                self.reposition()
                self.panel?.orderFrontRegardless()
            }
        }
        Log.write("indicator: Space・画面の変更に追従する")
    }

    /// 覚えた位置は「画面の左下からの距離」なので、どの画面でも同じ場所に出る
    private func savedOrigin(for panel: NSPanel) -> NSPoint {
        guard let screen = currentScreen() else { return NSPoint(x: 200, y: 300) }
        guard let offset = Defaults.indicatorOffset else { return defaultOrigin() }

        return IndicatorPlacement.origin(offset: offset, size: Self.size, visible: screen.visibleFrame)
    }

    /// 画面の左から 1/3 のあたりに**右端**が来るように置き、高さは下から約 1/3。
    ///
    /// 目印の左端を 1/3 に合わせると、体感では中央寄りに見えて邪魔になる。
    /// 幅のぶんだけ左にずらし、そこから少しだけ右に戻したところが落ち着く。
    private func defaultOrigin() -> NSPoint {
        guard let screen = currentScreen() else { return NSPoint(x: 200, y: 300) }
        let visible = screen.visibleFrame
        let size = IndicatorController.size
        return NSPoint(
            x: visible.minX + visible.width / 3 - size.width * 2,
            y: visible.minY + visible.height / 3)
    }


    deinit {
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
    }
}

@MainActor
final class IndicatorModel: ObservableObject {
    @Published var level: Float = 0
    @Published var isRunning = true
}

private struct IndicatorView: View {
    @ObservedObject var model: IndicatorModel
    let onPause: () -> Void
    let onResume: () -> Void
    let onClose: () -> Void
    let onMenu: () -> Void

    @State private var pulse = false

    var body: some View {
        HStack(spacing: 8) {
            pulsingDot
            Text("nobetsu")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(model.isRunning ? .primary : .secondary)
            bars

            Spacer(minLength: 4)

            // 押しても消えない。認識だけ止まって、再開できる形に変わる
            if model.isRunning {
                iconButton("pause.fill", help: "音声入力を一時停止してマイクを解放する", action: onPause)
            } else {
                iconButton("mic.fill", help: "再開", tint: .accentColor, action: onResume)
            }
            iconButton("ellipsis", help: "設定", action: onMenu)
            iconButton("xmark", help: "閉じる（ESC、⌘ の単独タップでも閉じます）", action: onClose)
        }
        .padding(.horizontal, 13)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
        .help(model.isRunning ? "録音中です。黙っていてもマイクを使っています。ドラッグで位置を調整できます" : "音声入力は一時停止中です。マイクは解放されています")
        .onAppear { pulse = true }
    }

    /// 認識中は赤く脈打ち、止めるとグレーで静止する。
    /// 状態が一目で分かることが、消えないことより大事
    private var pulsingDot: some View {
        ZStack {
            Circle()
                .fill(Color.red.opacity(model.isRunning ? 0.28 : 0))
                .frame(width: 17, height: 17)
                .scaleEffect(pulse && model.isRunning ? 1.35 : 0.85)
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
            Circle()
                .fill(model.isRunning ? Color.red : Color.secondary.opacity(0.45))
                .frame(width: 9, height: 9)
        }
        .animation(.easeInOut(duration: 0.2), value: model.isRunning)
    }

    /// 声が届いているかが分かる最小限の表示。棒3本で十分
    private var bars: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(Color.primary.opacity(0.55))
                    .frame(width: 2.5, height: height(for: index))
                    .animation(.easeOut(duration: 0.12), value: model.level)
            }
        }
    }

    private func height(for index: Int) -> CGFloat {
        let amplified = CGFloat(min(model.level * 14, 1))
        let weights: [CGFloat] = [0.6, 1.0, 0.75]
        return 5 + amplified * 13 * weights[index]
    }

    private func iconButton(
        _ symbol: String,
        help: String,
        tint: Color = .secondary,
        action: @escaping () -> Void
    ) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 21, height: 21)
            .background(Color.primary.opacity(0.08), in: Circle())
            .contentShape(Circle())
            .onTapGesture(perform: action)
            .help(help)
    }
}
