import AppKit
import SwiftUI

/// 画面下部に浮かぶ、認識中の文字を見せるための窓。
///
/// 絶対にフォーカスを奪ってはいけない。奪うと CGEvent で送った文字が
/// 挿入先のアプリではなくこの窓に入ってしまい、機能そのものが壊れる。
/// nonactivatingPanel + canBecomeKey = false + ignoresMouseEvents でそれを担保している。
@MainActor
final class OverlayController {

    private var panel: NonActivatingPanel?
    private let model = OverlayModel()

    func show() {
        if panel == nil { build() }
        guard let panel else { return }
        reposition(panel)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func update(committed: String, volatile: String, status: String) {
        model.committed = committed
        model.volatile = volatile
        model.status = status
    }

    private func build() {
        let width: CGFloat = 720
        let height: CGFloat = 132

        let p = NonActivatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false)

        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.isMovable = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let host = NSHostingView(rootView: OverlayView(model: model))
        host.frame = p.contentLayoutRect
        host.autoresizingMask = [.width, .height]
        p.contentView = host

        panel = p
    }

    private func reposition(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + 72)
        panel.setFrameOrigin(origin)
    }
}

/// キーウィンドウにならない panel。ここが肝
final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class OverlayModel: ObservableObject {
    @Published var committed = ""
    @Published var volatile = ""
    @Published var status = ""
}

private struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    /// 表示は末尾だけでよい。全文は挿入先に入っている
    private var tail: String {
        let all = model.committed + model.volatile
        return String(all.suffix(160))
    }

    private var committedTail: String {
        let all = model.committed + model.volatile
        let shown = all.suffix(160)
        let volatileCount = model.volatile.count
        let committedShown = max(0, shown.count - volatileCount)
        return String(shown.prefix(committedShown))
    }

    private var volatileTail: String {
        String(tail.suffix(model.volatile.count))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                    .opacity(model.status == "認識中" ? 1 : 0.25)
                Text(model.status)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("⌘ または ESC で停止")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            Text(committedTail)
                .foregroundStyle(.primary)
            + Text(volatileTail)
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 15))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }
}
