import SwiftUI
import UIKit

struct FrameSurface: UIViewRepresentable {
    let mailbox: LinkFrameMailbox
    let touch: (LinkTouch) -> Void
    var mode: LinkDisplayMode = .original
    var zoom: Double = 1.08
    func makeUIView(context: Context) -> FrameCanvas { FrameCanvas(mailbox: mailbox, touch: touch) }
    func updateUIView(_ view: FrameCanvas, context: Context) { view.configure(mode: mode, zoom: zoom) }
    static func dismantleUIView(_ view: FrameCanvas, coordinator: ()) { view.stop() }
}
@MainActor private final class FrameClock: NSObject {
    weak var view: FrameCanvas?
    @objc func tick() { view?.displayNewest() }
}
@MainActor final class FrameCanvas: UIView {
    let mailbox: LinkFrameMailbox
    let sendTouch: (LinkTouch) -> Void
    private let imageLayer = CALayer()
    private var mode = LinkDisplayMode.original
    private var zoom = 1.08
    private var previousSize = CGSize.zero
    private var viewport: LinkViewport { LinkViewport(size: bounds.size, mode: mode, zoom: zoom) }
    private var clock: CADisplayLink?
    private var activeTouch: UITouch?
    private var last = LinkTouch(phase: .up, x: 0, y: 0)
    init(mailbox: LinkFrameMailbox, touch: @escaping (LinkTouch) -> Void) {
        self.mailbox = mailbox; sendTouch = touch
        super.init(frame: .zero)
        backgroundColor = .black; isMultipleTouchEnabled = false
        clipsToBounds = true
        imageLayer.contentsGravity = .resize; imageLayer.magnificationFilter = .nearest
        layer.addSublayer(imageLayer)
        imageLayer.contents = mailbox.latest?.image
        let target = FrameClock(); target.view = self
        let clock = CADisplayLink(target: target, selector: #selector(FrameClock.tick))
        clock.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        clock.add(to: .main, forMode: .common); self.clock = clock
        accessibilityLabel = "Nintendo DS bottom touchscreen"
    }
    required init?(coder: NSCoder) { fatalError("Use init(mailbox:touch:)") }
    func displayNewest() {
        // Pixels and CGImage are prepared on the networking worker. Main only
        // swaps a layer reference; Core Animation performs screen composition.
        guard let frame = mailbox.take() else { return }
        imageLayer.contents = frame.image
    }
    private func emit(_ touch: UITouch, phase: LinkTouchPhase) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let point = touch.location(in: self)
        guard let (x, y) = viewport.pixel(at: point, starting: phase == .down) else { return }
        last = LinkTouch(phase: phase, x: x, y: y); sendTouch(last)
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard activeTouch == nil, let touch = touches.first else { return }
        guard viewport.pixel(at: touch.location(in: self), starting: true) != nil else { return }
        activeTouch = touch; emit(touch, phase: .down)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let activeTouch, touches.contains(activeTouch) else { return }; emit(activeTouch, phase: .move)
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { release(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { release(touches) }
    private func release(_ touches: Set<UITouch>) {
        guard let activeTouch, touches.contains(activeTouch) else { return }; emit(activeTouch, phase: .up); self.activeTouch = nil
    }
    func configure(mode: LinkDisplayMode, zoom: Double) {
        guard self.mode != mode || self.zoom != zoom else { return }
        cancelTouch(); self.mode = mode; self.zoom = zoom; setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        if previousSize != bounds.size { cancelTouch(); previousSize = bounds.size }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        imageLayer.frame = viewport.rect; CATransaction.commit()
    }
    func cancelTouch() {
        if activeTouch != nil { sendTouch(LinkTouch(phase: .up, x: last.x, y: last.y)); activeTouch = nil }
    }
    func stop() {
        cancelTouch()
        clock?.invalidate(); clock = nil; imageLayer.contents = nil
    }
}
