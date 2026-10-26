import SwiftUI

struct TVStudioBackground: View {
    var body: some View {
        ZStack {
            Color(red: 0.045, green: 0.043, blue: 0.041)
            RadialGradient(colors: [Color(red: 0.14, green: 0.13, blue: 0.12), .clear], center: .topTrailing,
                           startRadius: 0, endRadius: 1400)
        }.ignoresSafeArea()
    }
}
struct TVStudioEyebrow: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 20, weight: .medium, design: .rounded))
            .tracking(0.2).foregroundStyle(.gray)
    }
}
struct TVStudioButtonStyle: ButtonStyle {
    var card = false
    func makeBody(configuration: Configuration) -> some View {
        TVStudioButtonBody(configuration: configuration, card: card)
    }
}
private struct TVStudioButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let card: Bool
    @Environment(\.isFocused) private var focused
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        configuration.label
            .padding(card ? 20 : 18)
            .padding(.horizontal, card ? 0 : 12)
            .foregroundStyle(configuration.role == .destructive ? Color.red : (focused && !card ? .black : .white))
            .background(focused && !card ? Color.white : Color(white: focused ? 0.14 : 0.075),
                        in: RoundedRectangle(cornerRadius: card ? 26 : 40, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: card ? 26 : 40, style: .continuous)
                .stroke(Color.white.opacity(focused ? 0.9 : 0.14), lineWidth: focused ? 2 : 1))
            .shadow(color: .black.opacity(focused ? 0.4 : 0), radius: 22, y: 12)
            .scaleEffect(configuration.isPressed ? 0.98 : (focused && !reduceMotion ? 1.025 : 1))
            .opacity(enabled ? 1 : 0.4)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: focused)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
extension View {
    func tvStudioPanel() -> some View {
        self.padding(36)
            .background(Color(red: 0.085, green: 0.08, blue: 0.075), in: RoundedRectangle(cornerRadius: 30))
            .overlay(RoundedRectangle(cornerRadius: 30).stroke(.white.opacity(0.13)))
    }
}
