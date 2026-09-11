import AppKit
import SwiftUI
import Combine

/// メニューバーのアイコンとメニュー。
///
/// 以前は SwiftUI の `MenuBarExtra` で組んでいたが、そこに置いた `Toggle` は
/// **押した瞬間にメニューが閉じる**。チェックが入ったのか外れたのかを
/// もう一度開いて確かめることになり、切り替えた実感が持てない。
/// macOS の SwiftUI には閉じないようにする手段が無い
/// （`menuActionDismissBehavior(.disabled)` は macOS では使えない）ので、
/// AppKit の `NSMenu` に組み替え、チェック項目だけ自前のビューに載せている。
/// `NSMenuItem.view` の中で起きたクリックはメニューを閉じない
/// （目印のメニューにある長押し時間のスライダーと同じ仕組み）。
///
/// 代わりに、自前のビューの項目はマウスを載せても反転せず、矢印キーでも選べない。
/// チェックボックスは見ただけで押せると分かるので、そこは受け入れている。
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {

    private let controller: Controller
    private let statusItem: NSStatusItem
    private var observation: AnyCancellable?

    init(controller: Controller) {
        self.controller = controller
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()

        // objectWillChange は値が変わる「前」に来るので、次の周回で読み直す
        observation = controller.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon() }
    }

    // MARK: - アイコン

    /// | アイコン | 状態 |
    /// |---|---|
    /// | 警告の三角 | 許可が足りていない、または辞書が読めない |
    /// | 波形 | 待機中 |
    /// | 波形＋丸 | 認識中 |
    private var iconName: String {
        if controller.needsPermission || !controller.dictionaryIssues.isEmpty {
            return "exclamationmark.triangle.fill"
        }
        return controller.isRunning ? "waveform.circle.fill" : "waveform"
    }

    private func updateIcon() {
        let name = iconName
        guard statusItem.button?.image?.name() != name else { return }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "nobetsu")
        image?.setName(name)
        statusItem.button?.image = image
    }

    // MARK: - メニュー

    /// 開くたびに組み直す。状態に応じて項目が増減するため
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if controller.needsPermission {
            // ここは「動かない人が最初に開く場所」です。
            // 警告の三角を出したまま何も言わないと、壊れていると読まれて終わります。
            // 何が足りないのか・それが何の許可なのか・どこを開けばよいのかを、
            // このメニューだけで完結させます
            if let advice = controller.advice {
                menu.addItem(label(advice.title))
                for line in advice.lines { menu.addItem(label(line)) }
                menu.addItem(.separator())
                if advice.showsInputMonitoringButton {
                    menu.addItem(button("入力監視の設定を開く", #selector(openInputMonitoring)))
                }
                if advice.showsAccessibilityButton {
                    menu.addItem(button("アクセシビリティの設定を開く", #selector(openAccessibility)))
                }
            } else {
                menu.addItem(label("許可の状態を調べています"))
                menu.addItem(.separator())
                menu.addItem(button("入力監視の設定を開く", #selector(openInputMonitoring)))
            }
            // 救済措置。ダイアログを閉じてしまった人がここからやり直せる
            menu.addItem(button("許可をもう一度求める", #selector(requestPermissions)))
            menu.addItem(.separator())
        } else {
            menu.addItem(button(controller.isActive ? "停止" : "話しはじめる", #selector(toggleDictation)))
            menu.addItem(label(controller.status))
            menu.addItem(.separator())
            menu.addItem(label("⌘ を長押しで開始"))
            menu.addItem(label("もう一度 ⌘、または ESC で停止"))
            menu.addItem(.separator())
        }

        // チェックを切り替えてもメニューは閉じない（ファイル冒頭の説明を参照）
        menu.addItem(MenuToggle.item("ログイン時に起動", controller, \.launchAtLogin))
        menu.addItem(MenuToggle.item("開始と終了を音で知らせる", controller, \.soundEnabled))
        menu.addItem(MenuToggle.item("認識中の目印を出す", controller, \.showsIndicator))
        menu.addItem(MenuToggle.item("認識中の文字を画面に流す", controller, \.showsTranscript))

        let threshold = NSMenuItem(title: "開始までの長押し: \(Self.format(controller.holdThreshold)) 秒",
                                   action: nil, keyEquivalent: "")
        let thresholdMenu = NSMenu()
        for tenths in 5...20 {
            let value = Double(tenths) / 10
            let item = thresholdMenu.addItem(withTitle: "\(Self.format(value)) 秒",
                                             action: #selector(selectHoldThreshold(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.state = abs(controller.holdThreshold - value) < 0.05 ? .on : .off
        }
        menu.addItem(threshold)
        menu.setSubmenu(thresholdMenu, for: threshold)

        let command = NSMenuItem(title: "開始に使う ⌘", action: nil, keyEquivalent: "")
        let commandMenu = NSMenu()
        for choice in CommandKeyChoice.allCases {
            let item = commandMenu.addItem(withTitle: choice.title,
                                           action: #selector(selectCommandKey(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = choice.rawValue
            item.state = controller.commandKeyChoice == choice ? .on : .off
        }
        menu.addItem(command)
        menu.setSubmenu(commandMenu, for: command)

        menu.addItem(MenuToggle.item("入力先から離れたら止める", controller, \.stopsWhenFocusLeaves))
        menu.addItem(MenuToggle.item("遠距離マイク補正", controller, \.useFarField,
                                     isEnabled: !controller.isActive))

        menu.addItem(.separator())

        if !controller.dictionaryIssues.isEmpty {
            menu.addItem(label("一部の辞書を読み込めません（読めた規則は使用中）"))
            for issue in controller.dictionaryIssues {
                let item = button(issue.title, #selector(revealDictionaryIssue(_:)))
                item.representedObject = issue.url
                menu.addItem(item)
                menu.addItem(label(issue.reason))
            }
            menu.addItem(.separator())
        }
        menu.addItem(button("辞書を編集する", #selector(editDictionary)))
        menu.addItem(button("辞書を読み直す", #selector(reloadDictionary)))
        menu.addItem(button("引き継いだ辞書・バックアップを開く", #selector(openDictionaryStorage)))

        menu.addItem(.separator())

        // 利用者がバージョンを確かめられる唯一の場所。
        // 不具合の報告をもらうときに「どれを使っているか」が分からないと話が始まらない
        menu.addItem(label("nobetsu \(NobetsuApp.version)"))

        menu.addItem(button("nobetsu を終了", #selector(quit)))
    }

    private static func format(_ seconds: TimeInterval) -> String {
        String(format: "%.1f", seconds)
    }

    /// 押せない説明だけの行
    private func label(_ title: String) -> NSMenuItem {
        NSMenuItem(title: title, action: nil, keyEquivalent: "")
    }

    private func button(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    // MARK: - 操作

    @objc private func openInputMonitoring() { Permissions.openInputMonitoringSettings() }
    @objc private func openAccessibility() { Permissions.openAccessibilitySettings() }
    @objc private func requestPermissions() { controller.requestPermissions() }
    @objc private func toggleDictation() { controller.toggle() }
    @objc private func selectHoldThreshold(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Double else { return }
        controller.holdThreshold = value
    }
    @objc private func selectCommandKey(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let choice = CommandKeyChoice(rawValue: raw) else { return }
        controller.commandKeyChoice = choice
    }
    @objc private func revealDictionaryIssue(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.selectFile(url.path,
                                      inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
    }
    @objc private func editDictionary() { controller.editDictionary() }
    @objc private func reloadDictionary() { controller.reloadDictionary() }
    @objc private func openDictionaryStorage() { NSWorkspace.shared.open(DictionaryStorage.directory) }
    @objc private func quit() { NSApp.terminate(nil) }
}

/// 押してもメニューが閉じないチェック項目。
/// メニューバーと目印の「…」の両方で使う。幅と余白は長押し時間のスライダーに揃える
@MainActor
enum MenuToggle {

    static let width: CGFloat = 250

    static func item(_ title: String, _ controller: Controller,
                     _ keyPath: ReferenceWritableKeyPath<Controller, Bool>,
                     isEnabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem()
        let view = NSHostingView(rootView: ToggleRow(controller: controller, title: title,
                                                     keyPath: keyPath, isEnabled: isEnabled))
        view.frame = NSRect(x: 0, y: 0, width: width, height: 24)
        item.view = view
        return item
    }

    private struct ToggleRow: View {
        @ObservedObject var controller: Controller
        let title: String
        let keyPath: ReferenceWritableKeyPath<Controller, Bool>
        let isEnabled: Bool

        var body: some View {
            Toggle(title, isOn: Binding(get: { controller[keyPath: keyPath] },
                                        set: { controller[keyPath: keyPath] = $0 }))
                .toggleStyle(.checkbox)
                .disabled(!isEnabled)
                .padding(.horizontal, 12)
                .frame(width: MenuToggle.width, height: 24, alignment: .leading)
        }
    }
}
