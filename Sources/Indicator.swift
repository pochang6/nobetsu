import AppKit
import SwiftUI

/// 認識中であることを知らせる小さな目印。
///
/// 文字を大きく流す窓は、見た目は気持ちいいが入力先の文章と重なって邪魔になる。
/// テキスト入力欄は画面の下寄りにあることが多いので、こちらは**左上**に置く。
/// Windows の Win+H が同じ考え方で、あれは実際に邪魔にならない。
///
/// 出るときも消えるときも、ふわりと。唐突に現れると視線を奪う。
/// クリックすれば止められる。フォーカスは絶対に奪わない。
@MainActor
final class IndicatorController {

    /// クリックされたとき
    var onClick: (() -> Void)?

    private var panel: NonActivatingPanel?
    private let model = IndicatorModel()

    func show() {
        if panel == nil { build() }
        guard let panel else { return }

        reposition(panel)
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
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

    private func build() {
        let size = NSSize(width: 116, height: 36)
        let p = NonActivatingPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false)

        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isMovable = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let host = NSHostingView(rootView: IndicatorView(model: model) { [weak self] in
            self?.onClick?()
        })
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        p.contentView = host

        panel = p
    }

    /// 左上、メニューバーのすぐ下
    private func reposition(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.minX + 16,
            y: visible.maxY - panel.frame.height - 12)
        panel.setFrameOrigin(origin)
    }
}

@MainActor
final class IndicatorModel: ObservableObject {
    @Published var level: Float = 0
}

private struct IndicatorView: View {
    @ObservedObject var model: IndicatorModel
    let onClick: () -> Void

    @State private var pulse = false

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.28))
                    .frame(width: 16, height: 16)
                    .scaleEffect(pulse ? 1.35 : 0.85)
                    .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
            }

            Text("nobetsu")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)

            bars
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
        .contentShape(Capsule())
        .onTapGesture { onClick() }
        .help("クリックで停止（⌘ の長押し、または ESC でも止まります）")
        .onAppear { pulse = true }
    }

    /// 声が届いているかが分かる最小限の表示。棒3本で十分
    private var bars: some View {
        HStack(spacing: 2) {
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
        return 4 + amplified * 12 * weights[index]
    }
}
