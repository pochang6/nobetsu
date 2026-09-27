import Foundation

/// AX は主画面左上原点、AppKit は主画面左下原点。上下・左右に並ぶ画面にも対応する。
enum IndicatorPlacement {
    static func appKitFrame(_ axFrame: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: axFrame.minX, y: primaryHeight - axFrame.maxY,
               width: axFrame.width, height: axFrame.height)
    }

    /// 画面と対象はすべて AppKit 座標。重なりがなければ呼び出し側で予備の画面を選ぶ。
    static func screenIndex(screens: [CGRect], input: CGRect?, window: CGRect?, preferredIndex: Int? = nil) -> Int? {
        if let preferredIndex, screens.indices.contains(preferredIndex) { return preferredIndex }
        func usable(_ frame: CGRect?) -> CGRect? {
            guard let frame, !frame.isNull, !frame.isEmpty,
                  frame.origin.x.isFinite, frame.origin.y.isFinite,
                  frame.width.isFinite, frame.height.isFinite else { return nil }
            return frame
        }
        let input = usable(input)
        let window = usable(window)
        let target: CGRect?
        if let input, let window {
            // AX が文書・スクロールバック全体を返しても、見えているウィンドウ内だけを見る。
            // 食い違う座標や幅・高さ0の共通部分では、ウィンドウを安全な基準にする。
            target = usable(input.intersection(window)) ?? window
        } else {
            target = window ?? input
        }
        guard let target else { return nil }
        var selected: Int?
        var largest: CGFloat = 0
        for (index, screen) in screens.enumerated() {
            let overlap = screen.intersection(target)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            if area > largest {
                largest = area
                selected = index
            }
        }
        return selected
    }

    /// window server が実際に置いている枠（CG は主画面左上原点）が、AppKit で置いたつもりの枠と同じか。
    /// 外部モニターの抜き差しで window server だけが窓を元の画面へ戻すことがあり、
    /// そのとき AppKit の `frame` は古いまま残る。1pt 未満の差は丸めの違いとして無視する。
    static func serverMatches(appKit: CGRect, server: CGRect, primaryHeight: CGFloat) -> Bool {
        guard !server.isNull else { return true }
        let placed = appKitFrame(server, primaryHeight: primaryHeight)
        return abs(placed.minX - appKit.minX) < 1 && abs(placed.minY - appKit.minY) < 1
    }

    static func origin(offset: CGPoint, size: CGSize, visible: CGRect) -> CGPoint {
        clamp(CGPoint(x: visible.minX + offset.x, y: visible.minY + offset.y),
              size: size, visible: visible)
    }

    static func clamp(_ point: CGPoint, size: CGSize, visible: CGRect) -> CGPoint {
        CGPoint(x: min(max(point.x, visible.minX), max(visible.minX, visible.maxX - size.width)),
                y: min(max(point.y, visible.minY), max(visible.minY, visible.maxY - size.height)))
    }
}
