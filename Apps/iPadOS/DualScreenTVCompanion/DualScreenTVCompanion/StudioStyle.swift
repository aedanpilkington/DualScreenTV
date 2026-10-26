import SwiftUI

struct StudioPage<Content: View>: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 38) {
                HStack(spacing: 12) {
                    Image("BrandSplash").resizable().scaledToFit().frame(width: 240, height: 100).blendMode(.screen).accessibilityLabel("DualScreenTV")
                    Spacer()
                    Label("Local connection", systemImage: "circle.fill").font(.caption)
                        .foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 10)
                        .overlay(Capsule().stroke(.white.opacity(0.15)))
                }
                .padding(.bottom, 24)
                VStack(alignment: .leading, spacing: 18) {
                    Text(eyebrow).font(.system(size: 14, weight: .medium, design: .rounded)).tracking(0.2).foregroundStyle(.gray)
                    Text(title).font(.system(size: 46, weight: .semibold, design: .rounded)).tracking(-0.8).fixedSize(horizontal: false, vertical: true)
                    Text(subtitle).font(.title3).foregroundStyle(.secondary).lineSpacing(5)
                }
                VStack(alignment: .leading, spacing: 22, content: content)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(30)
                    .background(Color(red: 0.095, green: 0.09, blue: 0.085), in: RoundedRectangle(cornerRadius: 26))
                    .overlay(RoundedRectangle(cornerRadius: 26).stroke(.white.opacity(0.12)))
                Divider().padding(.top, 16)
                HStack {
                    Text("DualScreenTV / Companion")
                    Spacer()
                    Text("Two screens. One library.")
                }.font(.caption).foregroundStyle(.gray)
            }.padding(36).frame(maxWidth: 1000)
                .frame(maxWidth: .infinity)
        }
        .background(Color(red: 0.045, green: 0.043, blue: 0.041)).foregroundStyle(.white)
    }
}
struct StudioButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.headline).frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 18).padding(.horizontal, 22)
            .foregroundStyle(prominent ? Color.black : Color.white)
            .background(prominent ? Color.white : Color(white: 0.14), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(prominent ? 0 : 0.12)))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
