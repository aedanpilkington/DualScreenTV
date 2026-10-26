import SwiftUI
import UIKit

// Optional controls live around the streamed bottom screen; all emulation stays on TV.
struct DSSkin<Screen: View>: View {
    let circlePad: Bool
    let analog: (Int16, Int16) -> Void
    @ViewBuilder let screen: () -> Screen
    let button: (Int, Bool) -> Void
    private func key(_ label: String, _ bit: Int, width: CGFloat = 48) -> some View {
        DSKey(label: label) { button(bit, $0) }.frame(width: width, height: 48)
    }
    private var dpad: some View {
        VStack(spacing: 2) {
            key("↑", 4)
            HStack(spacing: 2) { key("←", 6); Color.clear.frame(width: 48, height: 48); key("→", 7) }
            key("↓", 5)
        }
    }
    private var face: some View {
        VStack(spacing: 2) {
            key("X", 9)
            HStack(spacing: 2) { key("Y", 1); Color.clear.frame(width: 48, height: 48); key("A", 8) }
            key("B", 0)
        }
    }
    private var left: some View { VStack(spacing: 24) { key("L", 10, width: 100);
        Group { if circlePad { CirclePad(changed: analog).frame(width: 148, height: 148) } else { dpad } };
        Text(circlePad ? "CIRCLE PAD" : "D-PAD").font(.system(size: 10, weight: .medium, design: .rounded)).tracking(0.3).foregroundStyle(.gray);
        key("SELECT", 2, width: 100) } }
    private var right: some View { VStack(spacing: 24) { key("R", 11, width: 100); face; key("START", 3, width: 100) } }
    var body: some View {
        GeometryReader { geometry in
            Group {
                if geometry.size.width > geometry.size.height {
                    HStack(spacing: 16) { left; screen().clipShape(RoundedRectangle(cornerRadius: 16)); right }
                } else {
                    VStack(spacing: 16) { screen(); HStack { left; Spacer(); right } }
                }
            }
            .padding(20)
            .background(LinearGradient(colors: [Color(white: 0.085), Color(white: 0.035)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.12)))
        }
    }
}
// UIKit sends cancellation and drag-out releases, including when the settings
// sheet or a system gesture interrupts a hold. Separate keys support chords.
private struct DSKey: UIViewRepresentable {
    let label: String
    let changed: (Bool) -> Void
    final class Coordinator: NSObject {
        var changed: (Bool) -> Void
        private var pressed = false
        init(_ changed: @escaping (Bool) -> Void) { self.changed = changed }
        @objc func down(_ sender: UIButton) { set(true, sender) }
        @objc func up(_ sender: UIButton) { set(false, sender) }
        private func set(_ value: Bool, _ sender: UIButton) {
            guard pressed != value else { return }
            pressed = value; sender.backgroundColor = UIColor(white: value ? 0.85 : 0.12, alpha: 1); sender.setTitleColor(value ? .black : .white, for: .normal); changed(value)
        }
        func release() { if pressed { pressed = false; changed(false) } }
    }
    func makeCoordinator() -> Coordinator { Coordinator(changed) }
    func makeUIView(context: Context) -> UIButton {
        let view = UIButton(type: .custom)
        view.setTitle(label, for: .normal); view.setTitleColor(.white, for: .normal)
        view.titleLabel?.font = .systemFont(ofSize: 18, weight: .bold)
        view.backgroundColor = UIColor(white: 0.12, alpha: 1); view.layer.cornerRadius = 24
        view.layer.borderWidth = 1; view.layer.borderColor = UIColor(white: 1, alpha: 0.15).cgColor
        view.accessibilityLabel = label
        view.addTarget(context.coordinator, action: #selector(Coordinator.down(_:)), for: [.touchDown, .touchDragEnter])
        view.addTarget(context.coordinator, action: #selector(Coordinator.up(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
        return view
    }
    func updateUIView(_ view: UIButton, context: Context) { context.coordinator.changed = changed }
    static func dismantleUIView(_ view: UIButton, coordinator: Coordinator) { coordinator.release() }
}


private struct CirclePad: UIViewRepresentable {
    let changed: (Int16, Int16) -> Void
    func makeUIView(context: Context) -> PadView { PadView(changed: changed) }
    func updateUIView(_ view: PadView, context: Context) { view.changed = changed }
    static func dismantleUIView(_ view: PadView, coordinator: ()) { view.release() }

    final class PadView: UIView {
        var changed: (Int16, Int16) -> Void
        private let thumb = UIView()
        private var offset = CGPoint.zero
        init(changed: @escaping (Int16, Int16) -> Void) {
            self.changed = changed
            super.init(frame: .zero)
            backgroundColor = UIColor(white: 0.06, alpha: 1)
            layer.borderWidth = 1; layer.borderColor = UIColor(white: 1, alpha: 0.16).cgColor
            thumb.backgroundColor = UIColor(white: 0.24, alpha: 1)
            thumb.layer.borderWidth = 1; thumb.layer.borderColor = UIColor(white: 1, alpha: 0.25).cgColor
            thumb.isUserInteractionEnabled = false
            addSubview(thumb)
            accessibilityLabel = "Circle Pad"
            accessibilityHint = "Drag from the centre to move. Release to stop."
        }
        required init?(coder: NSCoder) { fatalError("Not supported") }
        override func layoutSubviews() {
            super.layoutSubviews()
            layer.cornerRadius = bounds.width / 2
            let diameter = bounds.width * 0.48
            thumb.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            thumb.layer.cornerRadius = diameter / 2
            thumb.center = CGPoint(x: bounds.midX + offset.x, y: bounds.midY + offset.y)
        }
        private func move(_ touches: Set<UITouch>) {
            guard let touch = touches.first else { return }
            let point = touch.location(in: self)
            let radius = max(1, bounds.width * 0.25)
            let dx = point.x - bounds.midX, dy = point.y - bounds.midY
            let length = hypot(dx, dy)
            let scale = length > radius ? radius / length : 1
            offset = CGPoint(x: dx * scale, y: dy * scale)
            setNeedsLayout()
            let strength = min(1, length / radius)
            // Small central dead zone, then continuous magnitude through full tilt.
            let magnitude = max(0, (strength - 0.08) / 0.92)
            let divisor = max(1, length)
            changed(Int16(dx / divisor * magnitude * 32767), Int16(dy / divisor * magnitude * 32767))
        }
        func release() { offset = .zero; setNeedsLayout(); changed(0, 0) }
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { move(touches) }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { move(touches) }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { release() }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { release() }
    }
}
