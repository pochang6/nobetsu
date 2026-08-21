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

    /// 目印の上ではカーソルを消さない。
    ///
    /// macOS はキー入力中にマウスカーソルを隠す。nobetsu は文字を打ち込み続けるので、
    /// その仕様が延々と発動し、ボタンを押そうと近づいた瞬間にカーソルが消えてしまう。
    /// 目印の上に居る間だけ、打ち消し続ける
    private func startCursorKeeper() {
        cursorKeeper?.invalidate()
        cursorKeeper = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.keepCursorVisibleIfHovered() }
        }
    }

    /// 打ち込んだ直後にも呼ぶ。
    /// 一定間隔で出し直すだけだと、その合間に打ち込みが走って再び隠れ、点滅して見える。
    /// 隠される瞬間と出し直す瞬間を対にすると、ちらつかない
    func keepCursorVisibleIfHovered() {
        guard let panel, panel.isVisible else { return }
        guard panel.frame.contains(NSEvent.mouseLocation) else { return }
        NSCursor.setHiddenUntilMouseMoves(false)
        NSCursor.unhide()
    }

    func hide() {
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
        Defaults.indicatorOrigin = nil
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
            let origin = moved.frame.origin
            Task { @MainActor in Defaults.indicatorOrigin = origin }
        }

        panel = p
    }

    private func showMenu() {
        guard let menu = menuProvider?(), let contentView = panel?.contentView else { return }
        let point = NSPoint(x: IndicatorController.size.width - 26, y: 4)
        menu.popUp(positioning: nil, at: point, in: contentView)
    }

    // MARK: - 位置

    private func savedOrigin(for panel: NSPanel) -> NSPoint {
        guard let saved = Defaults.indicatorOrigin, isOnScreen(saved) else {
            return defaultOrigin()
        }
        return saved
    }

    /// 画面の左から 1/3 のあたりに**右端**が来るように置き、高さは下から約 1/3。
    ///
    /// 目印の左端を 1/3 に合わせると、体感では中央寄りに見えて邪魔になる。
    /// 幅のぶんだけ左にずらし、そこから少しだけ右に戻したところが落ち着く。
    private func defaultOrigin() -> NSPoint {
        guard let screen = NSScreen.main else { return NSPoint(x: 200, y: 300) }
        let visible = screen.visibleFrame
        let size = IndicatorController.size
        return NSPoint(
            x: visible.minX + visible.width / 3 - size.width * 2,
            y: visible.minY + visible.height / 3)
    }

    /// 外付けディスプレイを外したあとなど、画面の外に保存されていることがある
    private func isOnScreen(_ origin: NSPoint) -> Bool {
        let rect = NSRect(origin: origin, size: IndicatorController.size)
        return NSScreen.screens.contains { $0.visibleFrame.intersects(rect) }
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
            iconButton("xmark", help: "閉じる（ESC、⌘ の長押しでも閉じます）", action: onClose)
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
