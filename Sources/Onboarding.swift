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
    private var waitingSince: Date?
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
        model.message = ""
        model.showTroubleshooting = false
        waitingSince = Date()

        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        startPolling()
    }

    private func build() {
        let view = CoachView(
            model: model,
            openSettings: { [weak self] in self?.openAccessibilitySettings() },
            recheck: { [weak self] in self?.recheck() },
            dismiss: { [weak self] in self?.close() })

        let controller = NSHostingController(rootView: view)
        let w = NSWindow(contentViewController: controller)
        w.title = "nobetsu の設定"
        w.styleMask = [.titled, .closable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.setContentSize(NSSize(width: 560, height: 560))
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
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        // しばらく待っても変わらないなら、たいてい署名が変わったせいで
        // 「一覧はオンなのに拒否される」状態になっている。その対処を画面に出す
        if let since = waitingSince, Date().timeIntervalSince(since) > 6, !model.granted {
            model.showTroubleshooting = true
        }
        checkNow()
    }

    /// ボタンから手動で確認する
    func recheck() {
        model.message = isTrusted ? "" : "まだ許可が確認できません。"
        model.showTroubleshooting = true
        checkNow()
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
            model.message = "設定が完了しました。⌘ を長押しすると話しはじめられます。"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                self?.close()
            }
        } else {
            model.message = "設定を反映しています。まもなく使えるようになります…"
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
    @Published var showTroubleshooting = false
}

private struct CoachView: View {
    @ObservedObject var model: CoachModel
    let openSettings: () -> Void
    let recheck: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            VStack(alignment: .leading, spacing: 6) {
                Text("アクセシビリティの許可をお願いします")
                    .font(.system(size: 20, weight: .semibold))
                Text("nobetsu は、話した内容をそのとき使っているアプリへ直接入力します。\nmacOS ではこの動作に「アクセシビリティ」の許可が必要です。")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 10) {
                step(1, "「アクセシビリティ設定を開く」を押してください",
                     "「プライバシーとセキュリティ」の中のアクセシビリティが開きます")
                step(2, "一覧から nobetsu を探して、オンにしてください",
                     "一覧に見当たらない場合は、左下の + から nobetsu.app を追加してください")
                step(3, "オンにしたら、この画面に戻ってきてください",
                     "許可を確認しだい自動で有効になり、この画面は閉じます")
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))

            statusRow

            if model.showTroubleshooting && !model.granted {
                troubleshooting
            }

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                Button("閉じる") { dismiss() }
                Text("メニューバーの ⚠︎ からいつでも開き直せます")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("もう一度確認する") { recheck() }
                    .disabled(model.granted)
                Button(action: openSettings) {
                    Text("アクセシビリティ設定を開く").frame(minWidth: 170)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.granted)
            }
        }
        .padding(24)
        .frame(width: 560, height: 560)
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            Image(systemName: model.granted ? "checkmark.circle.fill" : "circle.dotted")
                .foregroundStyle(model.granted ? Color.green : Color.secondary)
            Text(statusText)
                .font(.system(size: 12))
                .foregroundStyle(model.granted ? .primary : .secondary)
        }
    }

    private var statusText: String {
        if model.granted {
            return model.message.isEmpty ? "許可を確認しました" : model.message
        }
        return model.message.isEmpty ? "許可を確認しています…" : model.message
    }

    /// 「一覧ではオンになっているのに有効にならない」ときの対処。
    /// 開発中のビルドは署名が毎回変わるため、macOS が別のアプリとして扱って拒否する
    private var troubleshooting: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("すでにオンになっているのに、この画面が変わらない場合", systemImage: "lightbulb")
                .font(.system(size: 12, weight: .medium))
            Text("""
                 一覧の nobetsu を、一度オフにしてから、もう一度オンにしてください。それで解決します。

                 アプリを更新すると macOS からは別のアプリに見えることがあり、
                 表示はオンのままでも、実際には許可されていない状態になります。
                 開発中のビルドで起きる現象で、配布版では起きません。
                 """)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
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
