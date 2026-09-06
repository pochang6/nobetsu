import Foundation

/// AX は主画面左上原点、AppKit は主画面左下原点。上下・左右に並ぶ画面にも対応する。
enum IndicatorPlacement {
    static func appKitFrame(_ axFrame: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: axFrame.minX, y: primaryHeight - axFrame.maxY,
               width: axFrame.width, height: axFrame.height)
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
