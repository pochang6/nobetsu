import AppKit
import SwiftUI

/// 権限の案内。
///
/// macOS の許可ダイアログはアプリごとに一度きりしか出ない。見逃すと二度と案内されない。
/// しかも許可が無い状態では ⌘ の長押しを検知できないので、
/// 「使おうとした瞬間に案内する」ことが原理的にできない。だから起動時に出す。
///
/// 判定は AXIsProcessTrusted() に頼らない。あれは起動中のプロセスで結果がキャッシュされ、
/// 許可しても false のままになることがある。実際にイベントタップを作れるかどうかで判断する。
@MainActor
final class PermissionCoach {

    /// タップを作れたときに呼ばれる。戻り値 false なら有効化に失敗している
    var onReady: (() -> Bool)?

    private var window: NSWindow?
    private var pollTimer: Timer?
    private var waitingSince: Date?
    private let model = CoachModel()

    // MARK: - 表示

    /// 許可が揃っていなければ案内を出す。戻り値は「もう使える状態か」
    @discardableResult
    func presentIfNeeded() -> Bool {
        if Permissions.canCreateEventTap() { return true }

        // 一覧に載らないと、そもそもユーザーがオンにできない。
        // どちらも純正ダイアログは出さず、案内はこのウィンドウ1枚に集約する
        Permissions.registerForAccessibility()

        present()
        return false
    }

    func present() {
        if window == nil { build() }
        refreshStatus()
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
            openAccessibility: { Permissions.openAccessibilitySettings() },
            openInputMonitoring: { Permissions.openInputMonitoringSettings() },
            relaunch: { Permissions.relaunch() },
            recheck: { [weak self] in self?.recheck() },
            dismiss: { [weak self] in self?.close() })

        let controller = NSHostingController(rootView: view)
        let w = NSWindow(contentViewController: controller)
        w.title = "nobetsu の設定"
        w.styleMask = [.titled, .closable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.setContentSize(NSSize(width: 580, height: 620))
        window = w
    }

    func close() {
        pollTimer?.invalidate()
        pollTimer = nil
        window?.orderOut(nil)
    }

    // MARK: - 見張り

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        refreshStatus()

        if let since = waitingSince, Date().timeIntervalSince(since) > 5, !model.ready {
            model.showTroubleshooting = true
        }

        guard model.tapWorks else { return }

        pollTimer?.invalidate()
        pollTimer = nil

        if onReady?() == true {
            model.ready = true
            model.message = "設定が完了しました。⌘ を長押しすると話しはじめられます。"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                self?.close()
            }
        } else {
            model.message = "有効にできませんでした。nobetsu を再起動してください。"
            model.showTroubleshooting = true
            startPolling()
        }
    }

    func recheck() {
        refreshStatus()
        model.showTroubleshooting = true
        if !model.tapWorks {
            model.message = "まだ許可が反映されていません。下の「nobetsu を再起動する」をお試しください。"
        }
        tick()
    }

    private func refreshStatus() {
        model.accessibility = Permissions.accessibilityGranted
        model.inputMonitoring = Permissions.inputMonitoringGranted
        model.tapWorks = Permissions.canCreateEventTap()
    }
}

@MainActor
final class CoachModel: ObservableObject {
    @Published var accessibility = false
    @Published var inputMonitoring = false
    @Published var tapWorks = false
    @Published var ready = false
    @Published var message = ""
    @Published var showTroubleshooting = false
}

private struct CoachView: View {
    @ObservedObject var model: CoachModel
    let openAccessibility: () -> Void
    let openInputMonitoring: () -> Void
    let relaunch: () -> Void
    let recheck: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            VStack(alignment: .leading, spacing: 6) {
                Text("使いはじめるまえに、2つの許可をお願いします")
                    .font(.system(size: 20, weight: .semibold))
                Text("nobetsu は ⌘ の長押しを待ち受け、話した内容をそのとき使っているアプリへ直接入力します。\nmacOS では、この2つの動作にそれぞれ許可が必要です。")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            permissionRow(
                granted: model.accessibility,
                title: "アクセシビリティ",
                detail: "認識した文字を、今使っているアプリへ入力するために使います",
                action: openAccessibility)

            permissionRow(
                granted: model.inputMonitoring,
                title: "入力監視",
                detail: "⌘ の長押しを待ち受けるために使います",
                action: openInputMonitoring)

            statusRow

            if model.showTroubleshooting && !model.ready {
                troubleshooting
            }

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                Button("閉じる") { dismiss() }
                Text("メニューバーの ⚠︎ から\nいつでも開き直せます")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("もう一度確認する") { recheck() }
                    .disabled(model.ready)
                Button(action: relaunch) {
                    Text("nobetsu を再起動する").frame(minWidth: 150)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.ready)
            }
        }
        .padding(24)
        .frame(width: 580, height: 620)
    }

    private func permissionRow(
        granted: Bool,
        title: String,
        detail: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 18))
                .foregroundStyle(granted ? Color.green : Color.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .medium))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button(granted ? "確認する" : "設定を開く", action: action)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            (granted ? Color.green.opacity(0.10) : Color.primary.opacity(0.045)),
            in: RoundedRectangle(cornerRadius: 10))
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            Image(systemName: model.tapWorks ? "checkmark.seal.fill" : "circle.dotted")
                .foregroundStyle(model.tapWorks ? Color.green : Color.secondary)
            Text(statusText)
                .font(.system(size: 12))
                .foregroundStyle(model.tapWorks ? .primary : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusText: String {
        if !model.message.isEmpty { return model.message }
        if model.tapWorks { return "準備ができました" }
        return "許可を確認しています…"
    }

    private var troubleshooting: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("上の2つをオンにしても変わらない場合", systemImage: "lightbulb")
                .font(.system(size: 12, weight: .medium))
            Text("""
                 「nobetsu を再起動する」を押してください。それで反映されます。

                 macOS は権限の判定をアプリの起動時に読み込むため、
                 起動したままの nobetsu には、あとから与えた許可が届きません。

                 なお、一覧に nobetsu があってオンに見えるのに効かない場合は、
                 一度オフにしてからオンにし直してください。
                 アプリを更新すると macOS からは別のアプリに見えることがあり、
                 表示はオンのままでも許可されていない状態になります。
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
}
