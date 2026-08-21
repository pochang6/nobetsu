import AppKit
import SwiftUI

/// 権限の案内。
///
/// ここで嘘をつかないことが大事。
/// macOS は権限の判定をアプリの起動時に読み込むため、
/// 起動したままのアプリには、あとから与えた許可が届かない。
/// AXIsProcessTrusted() の結果もプロセス内でキャッシュされる。
/// つまり「オンにしたら画面のチェックが緑に変わる」という作りは、そもそも成立しない。
///
/// だからこの画面は、状態を当てにいくのではなく、
/// 「2つオンにする → 再起動して反映する」という手順をはっきり示す。
/// もし運よくその場で有効になったら、それは検知して黙って先へ進める。
@MainActor
final class PermissionCoach {

    /// タップを作れたときに呼ばれる。戻り値 false なら有効化に失敗している
    var onReady: (() -> Bool)?

    private var window: NSWindow?
    private var pollTimer: Timer?
    private let model = CoachModel()

    // MARK: - 表示

    /// 許可が揃っていなければ案内を出す。戻り値は「もう使える状態か」
    @discardableResult
    func presentIfNeeded() -> Bool {
        if Permissions.canCreateEventTap() { return true }

        // 一覧に載らないと、そもそもユーザーがオンにできない。
        // 純正ダイアログは出さない。案内はこのウィンドウ1枚に集約する
        Permissions.registerForAccessibility()

        present()
        return false
    }

    func present() {
        if window == nil { build() }

        // 起動した時点の状態を控えておく。これは事実なので表示してよい
        model.launchAccessibility = Permissions.accessibilityGranted
        model.launchInputMonitoring = Permissions.inputMonitoringGranted
        model.appPath = Bundle.main.bundleURL.path
        model.ready = false
        model.message = ""

        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        startPolling()
    }

    private func build() {
        let view = CoachView(
            model: model,
            openAccessibility: { Permissions.openAccessibilitySettings() },
            openInputMonitoring: { Permissions.openInputMonitoringSettings() },
            copyPath: { [weak self] in
                guard let path = self?.model.appPath else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
                self?.model.message = "パスをコピーしました。選択画面で ⇧⌘G を押して貼り付けてください。"
            },
            revealInFinder: { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) },
            relaunch: { Permissions.relaunch() },
            dismiss: { [weak self] in self?.close() })

        let controller = NSHostingController(rootView: view)
        let w = NSWindow(contentViewController: controller)
        w.title = "nobetsu の設定"
        w.styleMask = [.titled, .closable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.setContentSize(NSSize(width: 600, height: 640))
        window = w
    }

    func close() {
        pollTimer?.invalidate()
        pollTimer = nil
        window?.orderOut(nil)
    }

    // MARK: - 見張り

    /// 運よくその場で有効になる場合もあるので、黙って見ておく。
    /// 表示で期待させることはしない
    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, Permissions.canCreateEventTap() else { return }
                guard self.onReady?() == true else { return }
                self.pollTimer?.invalidate()
                self.pollTimer = nil
                self.model.ready = true
                self.model.message = "設定が完了しました。⌘ を長押しすると話しはじめられます。"
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                    self?.close()
                }
            }
        }
    }
}

@MainActor
final class CoachModel: ObservableObject {
    @Published var launchAccessibility = false
    @Published var launchInputMonitoring = false
    @Published var appPath = ""
    @Published var ready = false
    @Published var message = ""
}

private struct CoachView: View {
    @ObservedObject var model: CoachModel
    let openAccessibility: () -> Void
    let openInputMonitoring: () -> Void
    let copyPath: () -> Void
    let revealInFinder: () -> Void
    let relaunch: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {

            VStack(alignment: .leading, spacing: 6) {
                Text("2つの許可をオンにしてください")
                    .font(.system(size: 20, weight: .semibold))
                Text("nobetsu は ⌘ の長押しを待ち受け、話した内容をそのとき使っているアプリへ直接入力します。\nmacOS では、この2つの動作にそれぞれ許可が必要です。")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            permissionRow(
                number: 1,
                grantedAtLaunch: model.launchAccessibility,
                title: "アクセシビリティ",
                detail: "認識した文字を、今使っているアプリへ入力するために使います",
                action: openAccessibility)

            permissionRow(
                number: 2,
                grantedAtLaunch: model.launchInputMonitoring,
                title: "入力監視",
                detail: "⌘ の長押しを待ち受けるために使います",
                action: openInputMonitoring)

            locationBox

            if model.ready {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    Text(model.message).font(.system(size: 12))
                }
            } else if !model.message.isEmpty {
                Text(model.message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            reflectBox

            HStack(spacing: 10) {
                Button("閉じる") { dismiss() }
                Text("メニューバーの ⚠︎ から\nいつでも開き直せます")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button(action: relaunch) {
                    Text("許可を反映して再起動").frame(minWidth: 160)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.ready)
            }
        }
        .padding(24)
        .frame(width: 600, height: 640)
    }

    private func permissionRow(
        number: Int,
        grantedAtLaunch: Bool,
        title: String,
        detail: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text("\(number)")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Color.accentColor, in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 14, weight: .medium))
                    if grantedAtLaunch {
                        Text("起動時は許可済み")
                            .font(.system(size: 10))
                            .foregroundStyle(.green)
                    }
                }
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)
            Button("設定を開く", action: action)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
    }

    /// 一覧に nobetsu が無いときの追加手順。ここでつまずく人が必ず出る
    private var locationBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("一覧に nobetsu が見当たらない場合", systemImage: "plus.rectangle.on.folder")
                .font(.system(size: 12, weight: .medium))

            Text("左下の ＋ を押すとアプリの選択画面が開きます。そこで ⇧⌘G を押し、下のパスを貼り付けてください。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Text(model.appPath)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
                Button("パスをコピー", action: copyPath)
                Button("Finder で表示", action: revealInFinder)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
    }

    /// 「オンにしたのに何も起きない」を先回りして説明する
    private var reflectBox: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("オンにしても、この画面はすぐには変わりません", systemImage: "info.circle")
                .font(.system(size: 12, weight: .medium))
            Text("macOS は許可の状態をアプリの起動時に読み込みます。そのため、起動したままの nobetsu には、あとから与えた許可が届きません。\n2つともオンにしたら、右下の「許可を反映して再起動」を押してください。それで使えるようになります。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}
