import AppKit
import SwiftUI

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
    /// 直近に文字を打ち込んだ時刻。カーソルが隠されるのはこの直後だけ
    private var lastInjectAt = Date.distantPast
    private var lastNudgeAt = Date.distantPast

    private static let size = NSSize(width: 222, height: 42)

    func show() {
        if panel == nil { build() }
        guard let panel else { return }

        panel.setFrameOrigin(savedOrigin(for: panel))
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
        } completionHandler: {
            panel.orderOut(nil)
        }
    }

    func update(level: Float) {
        model.level = level
    }

    /// 置き場所を初期位置に戻す
    func resetPosition() {
        Defaults.indicatorOffset = nil
        guard let panel else { return }
        panel.setFrameOrigin(defaultOrigin())
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
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

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
            forName: NSWindow.didMoveNotification,
            object: p,
            queue: .main
        ) { note in
            guard let moved = note.object as? NSWindow else { return }
            // 覚えるのは画面のどこか（左下からの距離）。絶対の座標で覚えると、
            // 別の画面で使ったときに画面の外や見当違いの場所へ出る
            let frame = moved.frame
            let screen = NSScreen.screens.first { $0.frame.intersects(frame) }
            guard let visible = screen?.visibleFrame else { return }
            let offset = NSPoint(x: frame.minX - visible.minX, y: frame.minY - visible.minY)
            Task { @MainActor in Defaults.indicatorOffset = offset }
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
    /// マウスのいる画面を使う。喋りはじめる直前に入力欄を押しているので、
    /// たいていそこが作業している画面になる
    private func currentScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    /// 覚えた位置は「画面の左下からの距離」なので、どの画面でも同じ場所に出る
    private func savedOrigin(for panel: NSPanel) -> NSPoint {
        guard let screen = currentScreen() else { return NSPoint(x: 200, y: 300) }
        guard let offset = Defaults.indicatorOffset else { return defaultOrigin() }

        let visible = screen.visibleFrame
        let size = IndicatorController.size
        // 画面の大きさは同じとは限らない。はみ出すなら画面の中へ寄せる
        let x = min(max(visible.minX + offset.x, visible.minX), visible.maxX - size.width)
        let y = min(max(visible.minY + offset.y, visible.minY), visible.maxY - size.height)
        return NSPoint(x: x, y: y)
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
        if let moveObserver {
            NotificationCenter.default.removeObserver(moveObserver)
        }
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
                iconButton("pause.fill", help: "一時停止", action: onPause)
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
        .help("ドラッグで移動できます")
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
