import AppKit
import SwiftUI
import ApplicationServices

/// アクセシビリティ許可の案内。
///
/// macOS の許可ダイアログは「アプリごとに一度きり」しか出ない。
/// 見逃すと、二度と何も出ないまま無反応なアプリが残る。
/// しかも許可が無い状態では ⌘ の長押しを検知できないので、
/// 「使おうとした瞬間に案内する」ことが原理的にできない。
///
/// だから起動時に、閉じるまで残るウィンドウで案内する。
/// 許可されたかどうかは自分で見張り、付いたら自動で有効化する。ユーザーに再起動させない。
@MainActor
final class PermissionCoach {

    /// 許可を検知したときに呼ばれる。戻り値 false ならプロセスを入れ替える必要がある
    var onGranted: (() -> Bool)?

    private var window: NSWindow?
    private var pollTimer: Timer?
    private let model = CoachModel()

    var isTrusted: Bool { AXIsProcessTrusted() }

    // MARK: - 表示

    /// 許可が無いときだけ案内を出す。戻り値は「すでに許可済みか」
    @discardableResult
    func presentIfNeeded() -> Bool {
        if isTrusted { return true }
        present()
        return false
    }

    func present() {
        if window == nil { build() }
        model.granted = isTrusted

        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        startPolling()
    }

    private func build() {
        let view = CoachView(
            model: model,
            openSettings: { [weak self] in self?.openAccessibilitySettings() },
            dismiss: { [weak self] in self?.close() })

        let controller = NSHostingController(rootView: view)
        let w = NSWindow(contentViewController: controller)
        w.title = "nobetsu の設定"
        w.styleMask = [.titled, .closable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.setContentSize(NSSize(width: 520, height: 470))
        window = w
    }

    func close() {
        pollTimer?.invalidate()
        pollTimer = nil
        window?.orderOut(nil)
    }

    // MARK: - 許可の見張り

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkNow() }
        }
    }

    private func checkNow() {
        guard isTrusted else { return }

        pollTimer?.invalidate()
        pollTimer = nil
        model.granted = true

        // 許可が付いた直後は、同じプロセスのままでも有効化できることが多い。
        // できなければプロセスを入れ替える。どちらにせよユーザーは何もしなくていい
        let activated = onGranted?() ?? false
        if activated {
            model.message = "有効になりました。⌘ を長押しすると始まります。"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.close()
            }
        } else {
            model.message = "反映のため、nobetsu を入れ替えています…"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                PermissionCoach.relaunch()
            }
        }
    }

    /// 自分を起動し直して、古いプロセスを畳む
    static func relaunch() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    // MARK: - 設定画面を開く

    /// macOS 26 では旧来の com.apple.preference.security 系の URL が
    /// 「アクセシビリティ機能」(VoiceOver やズーム) の画面に飛んでしまい、
    /// 権限一覧にたどり着けない。新しい PrivacySecurity.extension を先に試す。
    func openAccessibilitySettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
        ]
        for string in candidates {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
    }
}

@MainActor
final class CoachModel: ObservableObject {
    @Published var granted = false
    @Published var message = ""
}

private struct CoachView: View {
    @ObservedObject var model: CoachModel
    let openSettings: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {

            VStack(alignment: .leading, spacing: 6) {
                Text("あと1つだけ、許可が必要です")
                    .font(.system(size: 20, weight: .semibold))
                Text("nobetsu は、話した内容を今使っているアプリに直接打ち込みます。\nそのために macOS の「アクセシビリティ」の許可が要ります。")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 10) {
                step(1, "下のボタンで設定を開く",
                     "「プライバシーとセキュリティ > アクセシビリティ」が開きます")
                step(2, "一覧の nobetsu をオンにする",
                     "見つからない場合は左下の + から nobetsu.app を追加してください")
                step(3, "あとは何もしなくていい",
                     "許可を自動で見つけて有効にします。再起動も不要です")
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))

            HStack(spacing: 8) {
                Image(systemName: model.granted ? "checkmark.circle.fill" : "circle.dotted")
                    .foregroundStyle(model.granted ? Color.green : Color.secondary)
                Text(model.granted
                     ? (model.message.isEmpty ? "許可を確認しました" : model.message)
                     : "許可を待っています…")
                    .font(.system(size: 12))
                    .foregroundStyle(model.granted ? .primary : .secondary)
            }

            Spacer(minLength: 0)

            HStack {
                Button("あとで") { dismiss() }
                Spacer()
                Button(action: openSettings) {
                    Text("アクセシビリティ設定を開く").frame(minWidth: 180)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.granted)
            }
        }
        .padding(24)
        .frame(width: 520, height: 470)
    }

    private func step(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Color.accentColor, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}
