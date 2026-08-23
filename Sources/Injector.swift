import Foundation
import AppKit
import ApplicationServices

/// 最前面のアプリへ、日本語入力（IME）を経由せずに直接文字を打ち込む。
///
/// これが nobetsu の核心。macOS 標準の音声入力は認識した「よみ」を IME に流し込むため、
/// ライブ変換が未確定文節を書き換え続けるのと衝突して固まる。
/// DictationTranscriber は漢字かな交じりの確定済みテキストを返すので、
/// CGEvent の Unicode 直接入力を使えば IME を完全に迂回できる。変換が介在しないので衝突しない。
///
/// 途中経過は「楽観的に挿入して、変わった部分だけ打ち直す」方式で反映する。
/// 確定を待つと spike の計測どおり 20 秒以上グレーのまま放置されるため、実用にならない。
@MainActor
final class TextInjector {

    /// 直近に打ち込んだ未確定テキスト。確定するたびに空へ戻す
    private var pending: [Character] = []

    /// 打ち直しの頻度制限。途中経過は毎秒5回ほど飛んでくるので、そのまま流すと打鍵が渋滞する
    private var lastApplied = Date.distantPast
    private let minInterval: TimeInterval = 0.25
    private var queued: String?
    private var flushTimer: Timer?

    /// 打鍵中に立てるフラグ。自分が出したイベントで再入するのを防ぐ
    private(set) var isInjecting = false

    /// 打ち込んだ直後に呼ばれる。
    /// macOS はキー入力のたびにマウスカーソルを隠すので、
    /// 隠された直後に出し直したい相手へ知らせる
    var didInject: (() -> Void)?

    /// 収録中かどうか。停止後に遅れて届く結果を打ち込まないための門
    private var accepting = false

    /// 利用者が自分でキーを打つなどして、こちらの打ち込み済み位置が当てにならなくなった
    private var baselineLost = false

    /// 送信などで文脈が切れた。今の区間はもう打ち込まない
    private var discardCurrentSpan = false

    /// この区間はもう追いかけられない。次の確定まで何も打たない
    private var unfollowable = false

    /// `pending` の先頭のうち、**実際には入力欄に無い**文字数。
    ///
    /// 送信したあとも喋り続けている場合、送信済みの文章を「打ち込み済み」と見なして
    /// 差分を取る。そうすれば続きだけが空の入力欄へ入る。
    /// ただしその部分は画面上に存在しないので、**絶対に消しにいってはいけない**
    private var virtualPrefix = 0

    /// 送信した瞬間までに打ち込んであった内容。
    /// 認識器は同じ区間を喋り続けているので、次に届く未確定テキストはこれで始まる。
    /// 「これより先に増えた分」＝送信したあとに喋った分、として拾い直す
    private var submittedPrefix: [Character] = []

    /// 基準を失う直前まで打ち込んでいた内容。
    /// 認識は続いているので、次に届く未確定テキストはこれで始まるはず。
    /// そのときは「続きだけ」を打てば、消さずに、重複もせずに復帰できる
    private var abandonedPrefix: [Character] = []

    var isTrusted: Bool { AXIsProcessTrusted() }

    // MARK: - 収録の開始と終了

    func beginSession() {
        accepting = true
        baselineLost = false
        discardCurrentSpan = false
        unfollowable = false
        virtualPrefix = 0
        abandonedPrefix = []
        submittedPrefix = []
        clearPending()
    }

    /// 収録の終了。**ここから先に届く結果は一切打ち込まない。**
    ///
    /// 停止すると、認識器は最後の区間の確定結果を遅れて返してくる。
    /// それをそのまま適用すると、打ち込み済みの位置情報を失った状態で
    /// 同じ文章をもう一度打ってしまい、二重入力になる。
    /// 画面にはもう未確定分が出ているので、そのまま残すのが正しい。
    func endSession() {
        accepting = false
        baselineLost = false
        discardCurrentSpan = false
        unfollowable = false
        virtualPrefix = 0
        abandonedPrefix = []
        submittedPrefix = []
        clearPending()
    }

    // MARK: - 外部から呼ぶ入口

    /// 送信された。この文章はここで終わりなので、今の区間の続きは追いかけない。
    ///
    /// 「利用者が操作した」扱いにして復帰させると、送信して空になった入力欄へ
    /// 末尾の句点だけが遅れて届く。実際にそれが起きた。
    /// 送信は文脈の切れ目なので、次の区間から新しく始めるのが正しい。
    func userSubmitted() {
        guard accepting else { return }

        // **`pending` はもう空になっている。**
        //
        // Enter は「利用者が自分で操作した」でもあるので、`userTookOver()` が先に走り、
        // 打ち込み済みの内容は `abandonedPrefix` へ退避されている。
        // それを知らずに `pending`（＝空）を送信済みと見なすと、
        // 「何も打っていない」ことになり、次に届く未確定テキスト（その区間の全文）が
        // **丸ごと、空になった入力欄へ打ち直される。**
        // 送信した文章がそっくり次のメッセージに現れる形で実際に起きた。
        let typed = baselineLost ? abandonedPrefix : pending

        // 送信し終えた文はもう相手の手元にある。こちらは「打ち込み済み」として覚えておき、
        // ここから先に伸びた分だけを、空になった入力欄へ打つ。
        //
        // 短くなる方向へは更新しない。空行を入れようと Enter を2回叩くと、
        // 2回目は「何も打っていない」状態で来る。それに合わせて忘れてしまうと、
        // 1回目に送った分をもう一度打ち直すことになる
        if typed.count >= submittedPrefix.count { submittedPrefix = typed }
        Log.write("injector: 送信（打ち込み済み \(submittedPrefix.count) 文字）")
        clearPending()
        abandonedPrefix = []
        baselineLost = false
        discardCurrentSpan = true
        unfollowable = false
    }

    /// 未確定テキストの更新。頻度制限をかけて適用する
    func updateVolatile(_ text: String) {
        guard accepting else { return }
        if unfollowable { return }
        if discardCurrentSpan, !tryResumeAfterSubmit(with: text) { return }
        if baselineLost, !tryRecover(with: text) { return }
        guard canFollow(text) else { stopFollowingSpan(); return }
        queued = text
        scheduleFlush()
    }

    /// 基準を失った状態から復帰できるか試す。
    ///
    /// 認識そのものは止まっていないので、次に届く未確定テキストは
    /// 直前まで打ち込んでいた内容で始まる。始まっていれば、
    /// その続きだけを打てばよい。消す必要も、打ち直す必要もない。
    ///
    /// 始まっていない（言い直した、認識が変わった）場合は、この区間は諦めて
    /// 次の確定を待つ。中途半端に打つと文章が壊れる
    private func tryRecover(with text: String) -> Bool {
        let next = Array(text)
        guard next.count >= abandonedPrefix.count,
              Array(next[0..<abandonedPrefix.count]) == abandonedPrefix
        else {
            return false
        }
        pending = abandonedPrefix
        abandonedPrefix = []
        baselineLost = false
        return true
    }

    /// 送信したあとに、そのまま喋り続けたか確かめる。
    ///
    /// 送信すると区間を切り直すが、切れ目の確定が届くまで数秒かかることがある。
    /// その間ずっと捨てていると、続きを喋っているのに何も出てこない。
    /// 「固まった」と感じるのはこれで、実際にログでも空行を入れた直後に起きていた。
    ///
    /// 送信までに打ってあった内容で始まっていれば、そこから伸びた分は
    /// **送信後に喋った分**なので、打ってよい。
    /// 直後に続く句読点だけは、送信し終えた文の名残なので捨てる。
    /// 空の入力欄に句点だけが落ちる、という形で実際に起きた
    private func tryResumeAfterSubmit(with text: String) -> Bool {
        let next = Array(text)
        guard next.count > submittedPrefix.count,
              Array(next[0..<submittedPrefix.count]) == submittedPrefix
        else {
            return false
        }

        var head = submittedPrefix.count
        while head < next.count, TextInjector.isLeftover(next[head]) { head += 1 }
        guard head < next.count else { return false }

        // ここまでは打ち込み済みということにする。差分を取れば、続きだけが打たれる
        pending = Array(next[0..<head])
        virtualPrefix = head
        submittedPrefix = []
        discardCurrentSpan = false
        Log.write("injector: 送信のあとも喋り続けているので打ち込みを再開する（送信済み \(head) 文字）")
        return true
    }

    /// 送信し終えた文の名残。空になった入力欄へ落ちてほしくないもの
    private static func isLeftover(_ character: Character) -> Bool {
        "。、．，!?！？ 　\n".contains(character)
    }

    /// 区間の確定。頻度制限を無視して即座に適用し、その区間を締める
    func finalize(_ text: String) {
        guard accepting else { return }

        flushTimer?.invalidate()
        flushTimer = nil
        queued = nil

        // 送信で切れた区間、追いかけられなくなった区間は、ここで締める。中身は打たない
        if discardCurrentSpan || unfollowable {
            discardCurrentSpan = false
            unfollowable = false
            submittedPrefix = []
            pending = []
            virtualPrefix = 0
            return
        }

        // 基準を失っている場合も、続きとして繋がるなら打つ。
        // 繋がらないなら、打ち込み済みの文章は利用者の手元にあるので何もしない
        if baselineLost, !tryRecover(with: text) {
            baselineLost = false
            abandonedPrefix = []
            pending = []
            return
        }

        guard canFollow(text) else { stopFollowingSpan(); return }

        apply(text)
        // 確定した分はもう打ち直さない。次の区間は白紙から始まる
        pending = []
        virtualPrefix = 0
    }

    /// この更新を、そのまま差分で当てられるか。
    ///
    /// **送信済みの部分が書き直されていたら、当ててはいけない。**
    /// 認識は後から言い回しを直す。送信したあとにその直しが届くと、
    /// 食い違った位置まで消して打ち直そうとするが、そこはもう画面に無い。
    /// 結果として、送信し終えた文章の後半が丸ごと空の入力欄へ打ち込まれる。
    /// 実際に「送信した文の最後の100文字が入力欄に残る」形で起きた。
    ///
    /// 送信済みの文章はもう相手の手元にあり、こちらから直す手立ては無い。
    /// 直せないものは、追いかけないのが正しい
    private func canFollow(_ text: String) -> Bool {
        TextInjector.canFollow(pending: pending, next: Array(text), virtualPrefix: virtualPrefix)
    }

    /// 副作用が無いので、ここだけ取り出して確かめられる（`./test.sh`）
    nonisolated static func canFollow(pending: [Character], next: [Character], virtualPrefix: Int) -> Bool {
        guard virtualPrefix > 0 else { return true }
        return commonPrefixLength(pending, next) >= virtualPrefix
    }

    /// この区間はもう追えない。次の確定まで何も打たない
    private func stopFollowingSpan() {
        Log.write("injector: 送信済みの部分が書き直された → この区間は追いかけない")
        clearPending()
        submittedPrefix = []
        virtualPrefix = 0
        unfollowable = true
    }

    /// 利用者が自分でキーを打った、クリックした、送信した。
    ///
    /// こちらが把握している「打ち込み済みの末尾」はもう当てにならない。
    /// この状態で差分を適用すると、Backspace が利用者の文章を削りにいく。
    /// チャット欄で喋りながら Enter を押す、という操作は実際によく起きる。
    func userTookOver() {
        guard accepting, !baselineLost else { return }
        // 何を打ち込んであったかは覚えておく。次の未確定テキストと突き合わせて復帰する
        abandonedPrefix = pending
        clearPending()
        baselineLost = true
    }

    /// 中断。打ち込み済みの未確定分はそのまま残す（消すと入力が失われるため）
    func reset() {
        clearPending()
    }

    private func clearPending() {
        flushTimer?.invalidate()
        flushTimer = nil
        queued = nil
        pending = []
        virtualPrefix = 0
    }

    // MARK: - 適用

    private func scheduleFlush() {
        let elapsed = Date().timeIntervalSince(lastApplied)
        if elapsed >= minInterval {
            flushNow()
            return
        }
        guard flushTimer == nil else { return }
        flushTimer = Timer.scheduledTimer(withTimeInterval: minInterval - elapsed, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.flushTimer = nil
                self?.flushNow()
            }
        }
    }

    private func flushNow() {
        guard let text = queued else { return }
        queued = nil
        apply(text)
    }

    /// 現在打ち込み済みの未確定テキストを `text` の状態へ持っていく。
    /// 共通接頭辞は据え置き、食い違った末尾だけを削除して打ち直す。
    private func apply(_ text: String) {
        let next = Array(text)
        let (deleteCount, insert) = TextInjector.diff(pending: pending, next: next)

        guard deleteCount > 0 || !insert.isEmpty else { return }

        isInjecting = true
        defer {
            isInjecting = false
            lastApplied = Date()
            pending = next
            // 今の打鍵で macOS がカーソルを隠した。隠れたままにさせない
            didInject?()
        }

        if deleteCount > 0 { sendBackspaces(deleteCount) }
        if !insert.isEmpty { sendText(insert) }
    }

    /// 打ち込み済みの `pending` を `next` の状態へ持っていくのに必要な操作。
    /// 共通接頭辞は据え置き、食い違った末尾だけを消して打ち直す。
    ///
    /// 副作用が無いので、ここだけ取り出して確かめられる（`./test.sh`）
    nonisolated static func diff(pending: [Character], next: [Character]) -> (delete: Int, insert: String) {
        let common = commonPrefixLength(pending, next)
        return (pending.count - common, String(next[common...]))
    }

    nonisolated static func commonPrefixLength(_ a: [Character], _ b: [Character]) -> Int {
        var i = 0
        let n = min(a.count, b.count)
        while i < n, a[i] == b[i] { i += 1 }
        return i
    }

    // MARK: - CGEvent

    /// Unicode 文字列をそのままキーイベントとして送る。
    /// virtualKey を 0 にして keyboardSetUnicodeString を使うのが要点で、
    /// これならキーボードレイアウトにも IME にも依存せず文字が入る。
    private func sendText(_ text: String) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }

        // 1イベントに詰め込みすぎると取りこぼすアプリがあるので分割する
        let units = Array(text.utf16)
        let chunkSize = 16
        var index = 0

        while index < units.count {
            let end = min(index + chunkSize, units.count)
            var chunk = Array(units[index..<end])

            if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                down.setIntegerValueField(.eventSourceUserData, value: TriggerMonitor.injectedMagic)
                down.post(tap: .cgAnnotatedSessionEventTap)
            }
            if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                up.setIntegerValueField(.eventSourceUserData, value: TriggerMonitor.injectedMagic)
                up.post(tap: .cgAnnotatedSessionEventTap)
            }
            index = end
        }
    }

    private func sendBackspaces(_ count: Int) {
        guard count > 0, let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let deleteKey: CGKeyCode = 51  // Delete (Backspace)

        for _ in 0..<count {
            if let down = CGEvent(keyboardEventSource: source, virtualKey: deleteKey, keyDown: true) {
                down.setIntegerValueField(.eventSourceUserData, value: TriggerMonitor.injectedMagic)
                down.post(tap: .cgAnnotatedSessionEventTap)
            }
            if let up = CGEvent(keyboardEventSource: source, virtualKey: deleteKey, keyDown: false) {
                up.setIntegerValueField(.eventSourceUserData, value: TriggerMonitor.injectedMagic)
                up.post(tap: .cgAnnotatedSessionEventTap)
            }
        }
    }

}
