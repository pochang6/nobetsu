import AppKit
import Combine

/// メニューバーのアイコンとメニュー。
///
/// 以前は SwiftUI の `MenuBarExtra` で組んでいたが、そこに置いた `Toggle` は
/// **押した瞬間にメニューが閉じる**。チェックが入ったのか外れたのかを
/// もう一度開いて確かめることになり、切り替えた実感が持てない。
/// macOS の SwiftUI には閉じないようにする手段が無い
/// （`menuActionDismissBehavior(.disabled)` は macOS では使えない）ので、
/// AppKit の `NSMenu` に組み替え、チェック項目だけ自前のビュー（`StickyMenuItemView`）に
/// 載せている。`NSMenuItem.view` の中で起きたクリックはメニューを閉じない
/// （目印のメニューにある長押し時間のスライダーと同じ仕組み）。
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {

    private let controller: Controller
    private let statusItem: NSStatusItem
    private var observation: AnyCancellable?

    init(controller: Controller) {
        self.controller = controller
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = "nobetsu"
        super.init()

        let menu = NSMenu()
        menu.delegate = self
        // action の無い項目を AppKit に無効化させない（チェック項目は view だけで action を持たない）。
        // 代わりに説明だけの行は label() で明示的に無効にする
        menu.autoenablesItems = false
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
        Log.write("statusbar: アイコン \(name) image=\(image == nil ? "nil" : "ok") button=\(statusItem.button == nil ? "nil" : "ok") visible=\(statusItem.isVisible) length=\(statusItem.length)")
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

    /// 押せない説明だけの行。autoenablesItems を切っているので自分で無効にする
    private func label(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
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

/// 押してもメニューが閉じないチェック項目。メニューバーと目印の「…」の両方で使う。
///
/// NSMenu は項目を選ぶと必ず閉じる。開いたままにする道は「項目に view を持たせる」しかない。
/// view を持つ項目は AppKit が勝手に閉じないので、閉じるかどうかをこちらで決められる。
/// 代わりに見た目は全部こちらで描くことになるので、対象はチェックの付く項目だけに絞っている。
/// 見た目は標準の項目と同じ（左にチェック、載せると反転）にして、
/// 隣の普通の項目と並んでも区別がつかないようにする。nagara の同名のビューと同じ作り。
///
/// **この項目を入れるメニューは `autoenablesItems = false` にすること。**
/// action の無い項目は AppKit が勝手に無効化し、灰色で押せなくなる
@MainActor
enum MenuToggle {

    static func item(_ title: String, _ controller: Controller,
                     _ keyPath: ReferenceWritableKeyPath<Controller, Bool>,
                     isEnabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = isEnabled
        item.view = StickyMenuItemView(title: title,
                                       isOn: { controller[keyPath: keyPath] },
                                       select: { controller[keyPath: keyPath].toggle() })
        return item
    }
}

/// 選んでも閉じないメニュー項目の中身。
/// 標準の項目と隣り合うため、字下げと高さは標準に寄せてある。
/// ここがずれると、同じメニューの中で行が揃わずに目立つ
final class StickyMenuItemView: NSView {

    private static let font = NSFont.menuFont(ofSize: 0)
    private static let titleLeading: CGFloat = 22
    private static let trailing: CGFloat = 24
    private static let rowHeight = max(20, ceil(NSFont.menuFont(ofSize: 0).boundingRectForFont.height) + 3)

    private let title: String
    private let isOn: () -> Bool
    private let select: () -> Void
    private var isInside = false

    init(title: String, isOn: @escaping () -> Bool, select: @escaping () -> Void) {
        self.title = title
        self.isOn = isOn
        self.select = select
        let width = (title as NSString)
            .size(withAttributes: [.font: Self.font]).width + Self.titleLeading + Self.trailing
        super.init(frame: NSRect(x: 0, y: 0, width: ceil(width), height: Self.rowHeight))
        autoresizingMask = [.width]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("使わない") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isInside = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isInside = false
        needsDisplay = true
    }

    /// 選んでも閉じない。閉じるのはメニューの外を押したときと esc のとき（AppKit 任せ）
    override func mouseUp(with event: NSEvent) {
        guard enclosingMenuItem?.isEnabled ?? true else { return }
        select()
        // 同じメニューの他のチェックも描き直す
        var menu = enclosingMenuItem?.menu
        while let current = menu {
            for entry in current.items {
                (entry.view as? StickyMenuItemView)?.needsDisplay = true
            }
            menu = current.supermenu
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let enabled = enclosingMenuItem?.isEnabled ?? true
        let highlighted = enabled && (isInside || enclosingMenuItem?.isHighlighted == true)

        if highlighted {
            // selectedMenuItemColor は 11.0 で非推奨。いまのメニューの選択色はアクセント色
            NSColor.controlAccentColor.setFill()
            NSBezierPath(
                roundedRect: bounds.insetBy(dx: 5, dy: 0), xRadius: 4, yRadius: 4
            ).fill()
        }

        let color: NSColor
        if !enabled {
            color = .disabledControlTextColor
        } else {
            color = highlighted ? .selectedMenuItemTextColor : .labelColor
        }

        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: color]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(
            at: NSPoint(x: Self.titleLeading, y: (bounds.height - size.height) / 2),
            withAttributes: attributes)

        guard isOn() else { return }
        let configuration = NSImage.SymbolConfiguration(pointSize: Self.font.pointSize, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let check = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return }
        check.draw(in: NSRect(
            x: 8,
            y: (bounds.height - check.size.height) / 2,
            width: check.size.width,
            height: check.size.height))
    }
}
