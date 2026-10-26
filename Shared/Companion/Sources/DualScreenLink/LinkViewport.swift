import Foundation
import CoreGraphics

nonisolated enum LinkDisplayMode: String, CaseIterable {
    case original = "Original", overscan = "Overscan", fill = "Fill", stretch = "Stretch"
}
// One transform controls both composition and its inverse touch mapping.
nonisolated struct LinkViewport {
    let rect: CGRect
    init(size: CGSize, mode: LinkDisplayMode, zoom: Double) {
        let fit = min(size.width / 256, size.height / 192)
        let scale: Double
        switch mode {
        case .original: scale = fit
        case .overscan: scale = fit * min(1.3, max(1, zoom))
        case .fill: scale = max(size.width / 256, size.height / 192)
        case .stretch: scale = 0
        }
        let image = mode == .stretch ? size : CGSize(width: 256 * scale, height: 192 * scale)
        rect = CGRect(x: (size.width - image.width) / 2, y: (size.height - image.height) / 2,
                      width: image.width, height: image.height)
    }
    func pixel(at point: CGPoint, starting: Bool = false) -> (UInt16, UInt16)? {
        guard rect.width > 0, rect.height > 0, !starting || rect.contains(point) else { return nil }
        return (UInt16(max(0, min(255, Int((point.x - rect.minX) * 256 / rect.width)))),
                UInt16(max(0, min(191, Int((point.y - rect.minY) * 192 / rect.height)))))
    }
}
