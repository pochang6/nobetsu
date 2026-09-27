import AppKit

// 実機用。マイク・文字入力・個人設定を使わず、本番の目印と Space 通知を確認する。
enum Defaults {
    static var indicatorOffset: CGPoint? = CGPoint(x: 100, y: 100)
}
enum TriggerMonitor { static let injectedMagic: Int64 = 0 }
enum Log { static func write(_ message: String) {} }

@main
struct IndicatorSpacesCheck {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let suite = "nobetsu-display-check-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let screens = NSScreen.screens
        guard let primary = screens.first else { fatalError("No screens") }
        let indicator = IndicatorController(preferences: preferences)
        indicator.setRunning(false)
        let windowAX = CGRect(x: 0, y: 69, width: primary.frame.width, height: primary.frame.height - 69)
        let inputAX = CGRect(x: 0, y: -4327, width: 752, height: 4327 + primary.frame.height)
        indicator.follow(inputAXFrame: inputAX, windowAXFrame: windowAX)
        indicator.show()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        guard let panel = app.windows.first(where: { $0 is NonActivatingPanel }) else { fatalError("No indicator") }
        func checkScreen(_ index: Int, _ label: String) {
            let frame = panel.frame
            precondition(screens[index].frame.contains(CGPoint(x: frame.midX, y: frame.midY)), label)
            precondition(!panel.canBecomeKey && !panel.canBecomeMain, "Indicator must not take focus")
        }
        checkScreen(0, "Automatic selection")
        let choices = indicator.screenChoices
        precondition(choices.count == screens.count, "Every connected screen has a UUID")
        for (index, choice) in choices.enumerated() {
            indicator.pinScreen(id: choice.id)
            indicator.follow(inputAXFrame: inputAX, windowAXFrame: windowAX)
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            checkScreen(index, "Pinning must override input screen")
            let reloaded = IndicatorController(preferences: preferences)
            precondition(reloaded.fixedScreen?.id == choice.id, "Preference must survive restart")
            print("screen \(index): pinned across follow; preference restored")
        }
        indicator.useAutomaticScreen()
        indicator.follow(inputAXFrame: inputAX, windowAXFrame: windowAX)
        checkScreen(0, "Unpin returns to input screen")
        precondition(NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground, "Foreground changed")
        precondition(app.keyWindow == nil, "Key window changed")
        func wait(_ interval: Double) { RunLoop.current.run(until: Date().addingTimeInterval(interval)) }
        wait(0.5)
        for delay in [0.0, 0.01, 0.05, 0.15, 0.3] {
            indicator.hide()
            wait(delay)
            indicator.show()
            wait(0.6)
            precondition(panel.isVisible && panel.alphaValue == 1, "Rapid restart must remain visible")
            print("hide/show delay=\(delay) visible=\(panel.isVisible) alpha=\(panel.alphaValue) space=\(panel.isOnActiveSpace) frame=\(panel.frame)")
        }
        indicator.hide()
        wait(0.05)
        indicator.hide()
        wait(0.6)
        print("double hide visible=\(panel.isVisible) alpha=\(panel.alphaValue)")
        indicator.show()
        wait(0.6)
        print("show after double hide visible=\(panel.isVisible) alpha=\(panel.alphaValue)")
        // 入力欄の座標が変わらなくても、表示が失われたら復帰する。
        panel.orderOut(nil)
        indicator.follow(inputAXFrame: inputAX, windowAXFrame: windowAX)
        wait(0.8)
        precondition(panel.isVisible && panel.isOnActiveSpace && panel.alphaValue == 1, "Lost panel must recover")
        // Space 通知後の遅延処理が、利用者の停止を取り消さない。
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        wait(0.05)
        indicator.hide()
        wait(0.8)
        precondition(!panel.isVisible, "Space retry must not resurrect a hidden indicator")
        indicator.show()
        wait(0.4)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        wait(0.8)
        precondition(panel.isVisible && panel.isOnActiveSpace && panel.alphaValue == 1, "Space refresh must remain visible")
        checkScreen(0, "Space refresh preserves screen")
        precondition(NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground, "Space refresh stole focus")
        precondition(app.keyWindow == nil, "Space refresh became key")
        // 外部モニターの抜き差しでは、window server だけが窓を別の場所へ戻し、AppKit の frame は古いまま残る。
        // 実際の位置を問い合わせて置き直せているかを、window server 側だけ動かして再現して確かめる。
        func serverOrigin() -> CGPoint? {
            let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(panel.windowNumber)) as? [[String: Any]])?.first
            return (info?[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }?.origin
        }
        typealias ConnFn = @convention(c) () -> Int32
        typealias MoveFn = @convention(c) (Int32, Int32, UnsafePointer<CGPoint>) -> Int32
        let cgs = dlopen(nil, RTLD_NOW)
        if let connSym = dlsym(cgs, "CGSMainConnectionID"), let moveSym = dlsym(cgs, "CGSMoveWindow") {
            let expected = serverOrigin()
            var elsewhere = CGPoint(x: panel.frame.minX + 400, y: 200)
            _ = unsafeBitCast(moveSym, to: MoveFn.self)(unsafeBitCast(connSym, to: ConnFn.self)(), Int32(panel.windowNumber), &elsewhere)
            wait(0.3)
            precondition(serverOrigin() != expected, "Window server move must diverge from AppKit")
            // Space 切り替えのアニメーション中と見分けるため、1 秒以上たって同じずれが 2 回続いたときだけ直す
            indicator.follow(inputAXFrame: inputAX, windowAXFrame: windowAX)
            wait(0.1)
            precondition(serverOrigin() != expected, "A single mismatch (e.g. mid-animation) must not be nudged")
            wait(1.0)
            indicator.follow(inputAXFrame: inputAX, windowAXFrame: windowAX)
            wait(0.3)
            precondition(serverOrigin() == expected, "Diverged window server position must be restored")
            print("window server divergence: restored to \(expected.map { "\($0)" } ?? "-")")
        } else {
            print("SKIP: window server divergence (CGSMoveWindow unavailable)")
        }
        // 全画面の出入りで、全 Space に属するはずの窓が一部の Space にしか属さなくなる。
        // 所属を削って再現し、今の Space で表示に戻れるかを確かめる。
        typealias ActiveFn = @convention(c) (Int32) -> UInt64
        typealias SpacesFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
        typealias RemoveFn = @convention(c) (Int32, CFArray, CFArray) -> Void
        if let connSym = dlsym(cgs, "CGSMainConnectionID"), let activeSym = dlsym(cgs, "CGSGetActiveSpace"),
           let spacesSym = dlsym(cgs, "CGSCopySpacesForWindows"), let removeSym = dlsym(cgs, "CGSRemoveWindowsFromSpaces") {
            let conn = unsafeBitCast(connSym, to: ConnFn.self)()
            func current() -> NSWindow { app.windows.first { $0 is NonActivatingPanel && $0.isVisible }! }
            func onscreen(_ w: NSWindow) -> Bool {
                ((CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(w.windowNumber)) as? [[String: Any]])?
                    .first?[kCGWindowIsOnscreen as String] as? Bool) ?? false
            }
            func cutMembership() {
                let w = current()
                let all = unsafeBitCast(spacesSym, to: SpacesFn.self)(conn, 0x7, [w.windowNumber] as CFArray)?
                    .takeRetainedValue() as? [UInt64] ?? []
                let active = unsafeBitCast(activeSym, to: ActiveFn.self)(conn)
                unsafeBitCast(removeSym, to: RemoveFn.self)(conn, [w.windowNumber] as CFArray, all.filter { $0 != all.first { $0 != active } } as CFArray)
                wait(0.3)
                precondition(!onscreen(w), "Cutting Space membership must hide the window")
            }
            cutMembership()
            wait(2.1)
            indicator.follow(inputAXFrame: inputAX, windowAXFrame: windowAX)
            wait(0.8)
            precondition(onscreen(current()), "Window cut from the active Space must come back after follow")
            cutMembership()
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
            wait(0.8)
            precondition(onscreen(current()), "Window cut from the active Space must come back after a Space change")
            indicator.hide()
            wait(0.5)
            let hidden = app.windows.first { $0 is NonActivatingPanel }!
            hidden.orderFrontRegardless(); wait(0.1); cutMembership(); hidden.orderOut(nil)
            indicator.show()
            wait(0.5)
            precondition(onscreen(current()), "Window cut while hidden must come back on show")
            precondition(NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier, "Rebuild stole focus: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "-")")
            precondition(app.keyWindow == nil, "Rebuilt indicator became key")
            print("lost Space membership: recovered after follow, Space change and show")
        } else {
            print("SKIP: lost Space membership (CGS unavailable)")
        }
        indicator.hide()
        wait(0.6)
        print("PASS: Space recovery, window server divergence, lost Space membership, hide during recovery, rapid restart, pinning and no focus theft on \(screens.count) connected screens")
    }
}
