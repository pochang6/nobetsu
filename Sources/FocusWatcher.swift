import Foundation
import AppKit
@preconcurrency import ApplicationServices

/// 入力先の見張り番。**打ち込む相手がいなくなったら知らせる。**
///
/// 音声入力は、始めたことを忘れやすい。前のアプリで喋りはじめたまま Slack へ移り、
/// そのまま喋り続けると、長い独り言が同僚宛の入力欄へ流れ込む。
/// 誤爆すると取り返しがつかないので、既定では**入力先から離れた時点で止める**。
///
/// ## 通知ではなく、見に行く
///
/// 最初は Accessibility の「フォーカスが変わった」通知で作ったが、**逆に動いた。**
/// 離れても止まらず、戻ってきた瞬間に止まる。
/// 通知はアプリによって出たり出なかったりするうえ、前面に戻る一瞬だけ
/// 別の要素（ウインドウや入れ物）を指すため、その瞬間を「離れた」と誤解する。
///
/// そこで**一定間隔で今のフォーカスを見に行く**方式に変えた。
/// アプリ任せの通知に頼らないので、どのアプリでも同じように動く。
/// さらに「文字を入れられない場所にいる」が2回続くまで止めない。
/// 一瞬の状態変化では止まらず、本当に離れたときだけ止まる。
///
/// アプリの切り替えだけは通知の方が速いので、そちらも併用する。
///
/// ## 「見えない」は「離れた」ではない
///
/// 入力欄を一切教えてくれないアプリがある（Claude や Slack のような Electron 製が典型）。
/// そこで「フォーカスが取れない＝離れた」と判断したところ、
/// **喋りはじめて 0.8 秒で必ず止まる**という、使い物にならないものができた。
/// 分からないときは何もしない。止めるのは、離れたと**確かめられた**ときだけ。
///
/// ## 問い合わせは別の道でやる
///
/// 相手のアプリへの問い合わせは同期的で、応答が無ければその場で待たされる。
/// これをメインスレッドでやると、**キーの見張り（イベントタップ）まで巻き添えで止まる。**
/// タップは OS のキー入力の通り道なので、そうなると Mac 全体が固まったように見える。
/// だから問い合わせは別のキューへ逃がし、結果だけを持ち帰る。
@MainActor
final class FocusWatcher {

    /// 入力先から離れた。引数はログと通知に使う理由
    var onLeave: ((String) -> Void)?
    /// 同じアプリの中で、別の入力欄へフォーカスが移った
    var onMovedWithinApp: (() -> Void)?
    /// 入力欄と前面ウィンドウの AX 座標。文字列の内容は取得・転送しない。
    var onGeometry: ((CGRect?, CGRect?) -> Void)?
    private var generation: UInt64 = 0

    private var notifications: [NSObjectProtocol] = []
    private var poll: Timer?
    private var targetPID: pid_t = 0
    private var targetName = ""
    private var focused: AXUIElement?
    /// 「文字を入れられない場所にいる」が続いた回数
    private var strikes = 0
    /// このアプリの入力欄が見えたことがあるか。一度も見えないなら深追いしない
    private var exposesFocus = false
    /// Electron 製アプリに「入力欄の場所を用意して」と頼んだか。頼むのは一度だけ
    private var didTryManual = false
    /// 問い合わせ中。返事を待たずに次を投げない
    private var querying = false
    /// 入力欄から離れていた。戻ってきたときにカーソルの位置を見る
    private var wasAway = false
    /// 離れたことは知らせ済み。同じことを 0.4 秒ごとに言わない
    private var reportedLeave = false
    /// いま基準にしている場所は、文字を入れられる場所か
    private var focusedAcceptsText = false

    /// 相手のアプリへの問い合わせ専用。**メインスレッドでやってはいけない**
    private static let queue = DispatchQueue(label: "dev.pochang6.nobetsu.focus")

    /// 見に行く間隔。速すぎても相手のアプリに問い合わせる回数が増えるだけ
    private static let interval: TimeInterval = 0.4
    /// これだけ続いたら本当に離れたと見なす
    private static let strikesToStop = 2
    /// 応答しないアプリに引きずられて、こちらが固まらないための上限
    nonisolated private static let messagingTimeout: Float = 0.2

    // MARK: - 見張りの開始と終了

    func start() {
        stop()

        guard let front = NSWorkspace.shared.frontmostApplication else {
            Log.write("focus: 前面のアプリが分からないので見張らない")
            return
        }
        targetPID = front.processIdentifier
        targetName = front.localizedName ?? front.bundleIdentifier ?? "?"

        focused = nil
        exposesFocus = false
        didTryManual = false
        strikes = 0
        // ここで問い合わせない。同期の問い合わせをメインスレッドでやると
        // キーの見張りを巻き添えにする。入力欄が見えるかどうかは、見張りながら判る
        Log.write("focus: 入力先を見張る（\(targetName)）")

        let center = NSWorkspace.shared.notificationCenter

        // アプリの切り替えだけは通知の方が速い。間隔を待たずに止める
        notifications.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let pid = app?.processIdentifier ?? 0
                let name = app?.localizedName ?? "?"
                let isSelf = app?.bundleIdentifier == Bundle.main.bundleIdentifier
                Task { @MainActor in
                    FocusWatcher.shared?.appActivated(pid: pid, name: name, isSelf: isSelf)
                }
            })

        notifications.append(center.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main) { _ in
                Task { @MainActor in
                    FocusWatcher.shared?.leave("別の画面へ移った")
                }
            })

        FocusWatcher.shared = self
        poll = Timer.scheduledTimer(withTimeInterval: FocusWatcher.interval, repeats: true) { _ in
            Task { @MainActor in FocusWatcher.shared?.check() }
        }
    }

    func stop() {
        generation &+= 1
        poll?.invalidate()
        poll = nil
        querying = false
        exposesFocus = false
        reportedLeave = false
        wasAway = false
        focusedAcceptsText = false
        let center = NSWorkspace.shared.notificationCenter
        for token in notifications { center.removeObserver(token) }
        notifications = []
        focused = nil
        strikes = 0
        targetPID = 0
        targetName = ""
    }

    private var isWatching: Bool { poll != nil }

    nonisolated(unsafe) private static weak var shared: FocusWatcher?

    // MARK: - 見に行く

    private func check() {
        guard isWatching else { return }
        guard let front = NSWorkspace.shared.frontmostApplication else { return }

        // 自分（目印のメニューやメニューバー）を触っている間は、入力先は変わっていない。
        // ここで止めると、設定を見ようとしただけで音声入力が終わってしまう
        if front.bundleIdentifier == Bundle.main.bundleIdentifier { return }

        if front.processIdentifier != targetPID {
            leave("別のアプリへ移った（\(targetName) → \(front.localizedName ?? "?")）")
            return
        }

        guard !querying else { return }
        querying = true

        let pid = targetPID
        let token = generation
        let known = focused
        let everSeen = exposesFocus
        let enableManual = !didTryManual
        didTryManual = true

        FocusWatcher.queue.async { [weak self] in
            let verdict = FocusWatcher.inspect(pid: pid, known: known,
                                               everSeen: everSeen, enableManual: enableManual)
            let geometry = FocusWatcher.geometry(pid: pid)
            Task { @MainActor in
                guard let self, self.generation == token, self.targetPID == pid else { return }
                self.apply(verdict)
                guard self.isWatching, self.generation == token else { return }
                self.onGeometry?(geometry.input, geometry.window)
            }
        }
    }

    /// 問い合わせの結果。メインスレッドへ持ち帰るのはこれだけ
    private enum Verdict {
        /// この見張りで初めて入力欄が見えた。ここが基準になる
        case firstSeen(AXUIElement, String, Bool)
        /// 始めたときと同じ場所にいる
        case same
        /// 同じアプリの中で、別の「文字を入れられる場所」へ移った
        case movedToText(AXUIElement, String)
        /// 文字を入れられない場所にいる
        case notText(String)
        /// 分からなかった。**分からないことを理由に止めてはいけない**
        case unknown
    }

    /// ここだけ別のキューで動く。相手が応答しなくても、メインスレッドは巻き込まれない
    private nonisolated static func inspect(
        pid: pid_t, known: AXUIElement?, everSeen: Bool, enableManual: Bool
    ) -> Verdict {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)

        guard let element = focusedElement(of: app) else {
            if enableManual { requestAccessibilityTree(of: app) }
            // 一度でも見えていたなら、見えなくなったのは「離れた」。
            // 一度も見えていないなら、このアプリは元々教えてくれないだけ
            return everSeen ? .notText("フォーカスなし") : .unknown
        }

        // **最初に見えた場所は、役割を問わず基準にする。**
        // 利用者はいまそこで喋りはじめたのだから、そこが入力先に決まっている。
        // 見慣れない役割名を返すアプリを、いきなり「入力欄ではない」と切り捨てない
        guard everSeen else {
            let name = role(of: element)
            // 「他のアプリを触っている間も、ここへ書き込めるか」を記録しておく。
            // フォーカスを持っていない入力欄へ文字を入れるには、キーではなく
            // Accessibility で直接書くしかない。書けるかどうかはアプリしだいなので、
            // まず実物で確かめる
            return .firstSeen(element, "\(name) / \(writability(of: element))",
                              acceptsText(element, role: name))
        }

        if let known, CFEqual(known, element) { return .same }

        let role = role(of: element)
        return acceptsText(element, role: role) ? .movedToText(element, role) : .notText(role)
    }

    private nonisolated static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
              position.x.isFinite, position.y.isFinite, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: position, size: size)
    }

    private nonisolated static func geometry(pid: pid_t) -> (input: CGRect?, window: CGRect?) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        var input: CGRect?
        if let element = focusedElement(of: app), acceptsText(element, role: role(of: element)) {
            input = frame(of: element)
        }
        var window: CFTypeRef?
        var windowFrame: CGRect?
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
           let window, CFGetTypeID(window) == AXUIElementGetTypeID() {
            windowFrame = frame(of: window as! AXUIElement)
        }
        return (input, windowFrame)
    }

    /// Chromium/Electron 製のアプリに「入力欄の場所を用意して」と頼む。
    ///
    /// Claude・Slack・Google Chrome などは、頼まれるまで入力欄の情報を作らない。
    /// そのままでは `AXFocusedUIElement` が空を返し続け、
    /// **テキストエリアから離れたことを検知できない。**
    /// 支援技術（スクリーンリーダー）が使うのと同じ頼み方で、一度立てれば以後は見える。
    ///
    /// 相手のアプリに負担をかける操作なので、頼むのは見張りはじめの一度だけにする
    private nonisolated static func requestAccessibilityTree(of app: AXUIElement) {
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    private func apply(_ verdict: Verdict) {
        querying = false
        guard isWatching else { return }

        switch verdict {
        case .firstSeen(let element, let role, let isText):
            Log.write("focus: 入力欄が見えた (\(role))")
            exposesFocus = true
            focused = element
            focusedAcceptsText = isText
            strikes = 0
            if isText { returnedToInput(element) }
        case .same:
            strikes = 0
            if focusedAcceptsText { returnedToInput(focused) }
        case .movedToText(let element, let role):
            Log.write("focus: 同じアプリの別の入力欄へ移った (\(role))")
            focused = element
            focusedAcceptsText = true
            strikes = 0
            returnedToInput(element)
            onMovedWithinApp?()
        case .notText(let role):
            wasAway = true
            strike("入力欄から離れた (\(role))")
        case .unknown:
            // 一瞬取れないことは普通にある。見えないだけで、離れたとは限らない
            strikes = 0
        }
    }

    /// 入力欄へ戻ってきた。カーソルが先頭へ戻されていないか見に行く
    private func returnedToInput(_ element: AXUIElement?) {
        reportedLeave = false
        guard wasAway, let element else { return }
        wasAway = false
        FocusWatcher.queue.async { FocusWatcher.moveCaretToEndIfReset(element) }
    }

    /// 一瞬の状態変化で止めない。続いたときだけ本気にする
    private func strike(_ reason: String) {
        strikes += 1
        guard strikes >= FocusWatcher.strikesToStop else {
            Log.write("focus: \(reason) …様子を見る (\(strikes)/\(FocusWatcher.strikesToStop))")
            return
        }
        leave(reason)
    }

    private func appActivated(pid: pid_t, name: String, isSelf: Bool) {
        guard isWatching else { return }
        if isSelf { return }
        guard pid != targetPID else { return }
        leave("別のアプリへ移った（\(targetName) → \(name)）")
    }

    /// 離れたことを知らせる。**ここでは止めない。**
    /// 止めるか、そのまま続けるかは設定しだいなので、決めるのは呼び出し側
    private func leave(_ reason: String) {
        guard isWatching, !reportedLeave else { return }
        reportedLeave = true
        Log.write("focus: \(reason)")
        onLeave?(reason)
    }

    /// 止めない設定のとき、新しい入力先へ見張りを付け替える。
    /// 移った先でも、カーソルが先頭に戻されていたら末尾へ送りたいので `wasAway` は立てる
    func retarget() {
        guard isWatching, let front = NSWorkspace.shared.frontmostApplication else { return }
        if front.bundleIdentifier == Bundle.main.bundleIdentifier { return }

        generation &+= 1
        querying = false
        targetPID = front.processIdentifier
        targetName = front.localizedName ?? front.bundleIdentifier ?? "?"
        focused = nil
        focusedAcceptsText = false
        exposesFocus = false
        didTryManual = false
        strikes = 0
        reportedLeave = false
        wasAway = true
        Log.write("focus: 見張りを付け替える（\(targetName)）")
    }

    // MARK: - Accessibility の小物

    private nonisolated static func focusedElement(of app: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
            let value else { return nil }
        return (value as! AXUIElement)
    }

    private nonisolated static func role(of element: AXUIElement) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXRoleAttribute as CFString, &value) == .success,
            let text = value as? String else { return "不明" }
        return text
    }

    /// ここへ文字を打ち込めるか。
    ///
    /// **「選択範囲を持っているか」で見てはいけない。**
    /// Chromium は入れ物（`AXGroup`）にもそれを持たせるので、
    /// 文章の上をクリックしただけで「まだ入力欄にいる」と誤判定した。
    /// 同じ理由で `AXWebArea`（ページそのもの）も入力欄ではない。
    /// ページに focus が乗っているだけで、そこへ打った文字はどこへも入らない。
    ///
    /// 役割で決め、決められないものだけ「値を書き換えられるか」で確かめる。
    /// 入れ物の値は書き換えられないので、ここで落ちる
    private nonisolated static func acceptsText(_ element: AXUIElement, role: String) -> Bool {
        let textRoles: Set<String> = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String,
            "AXSearchField",
        ]
        if textRoles.contains(role) { return true }

        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(
            element, kAXValueAttribute as CFString, &settable) == .success {
            return settable.boolValue
        }
        return false
    }

    /// この入力欄へ、フォーカスを持たないまま書き込めるか。
    /// できるなら「よそを触っていても、元の入力欄へ入れ続ける」が作れる
    private nonisolated static func writability(of element: AXUIElement) -> String {
        var value: DarwinBoolean = false
        var selected: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &value)
        AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &selected)
        return "値=\(value.boolValue) 選択文字=\(selected.boolValue)"
    }

    /// 入力欄へ戻ってきたとき、カーソルが先頭に戻されていたら末尾へ送る。
    ///
    /// よそを触って戻ると、アプリがカーソルを先頭に置き直すことがある。
    /// そこへ打ち込むと、書きかけの文章の**頭に**続きが入る。
    /// 常識的には末尾から続けたい。
    ///
    /// **自分でカーソルを置いた場合は触らない。** 途中に差し込みたいことはあるし、
    /// そのときは押した場所が優先されるべき。
    /// 動かすのは「先頭ちょうど・選択なし・中身は空でない」ときだけに絞る。
    /// 人が自分で文章のいちばん先頭を狙って押すことは、まず無い
    private nonisolated static func moveCaretToEndIfReset(_ element: AXUIElement) {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXValueAttribute as CFString, &value) == .success,
            let text = value as? String, !text.isEmpty else { return }

        var current: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &current) == .success,
            let currentValue = current,
            CFGetTypeID(currentValue) == AXValueGetTypeID() else { return }

        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(currentValue as! AXValue, .cfRange, &range) else { return }
        guard range.location == 0, range.length == 0 else { return }

        var end = CFRange(location: (text as NSString).length, length: 0)
        guard let moved = AXValueCreate(.cfRange, &end) else { return }
        AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, moved)
        Log.write("focus: カーソルが先頭に戻されていたので末尾へ送った")
    }
}
