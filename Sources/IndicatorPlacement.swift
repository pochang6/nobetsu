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

    static func origin(offset: CGPoint, size: CGSize, visible: CGRect) -> CGPoint {
        clamp(CGPoint(x: visible.minX + offset.x, y: visible.minY + offset.y),
              size: size, visible: visible)
    }

    static func clamp(_ point: CGPoint, size: CGSize, visible: CGRect) -> CGPoint {
        CGPoint(x: min(max(point.x, visible.minX), max(visible.minX, visible.maxX - size.width)),
                y: min(max(point.y, visible.minY), max(visible.minY, visible.maxY - size.height)))
    }
}
