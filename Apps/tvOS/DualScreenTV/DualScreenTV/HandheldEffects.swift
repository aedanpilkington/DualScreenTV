import SwiftUI
struct HandheldEffects: ViewModifier {
    let enabled: Bool
    let source: CGSize
    let display: CGSize
    func body(content: Content) -> some View {
        if #available(tvOS 17.0, *), enabled {
            content.colorEffect(ShaderLibrary.handheldLCD(.float2(Float(source.width), Float(source.height)), .float2(Float(display.width), Float(display.height)), .float(UserDefaults.standard.bool(forKey: "graphics.gb.colourCorrection") ? 1 : 0), .float(UserDefaults.standard.bool(forKey: "graphics.gb.lcd") ? 1 : 0)))
        } else { content }
    }
}
