#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;
[[ stitchable ]] half4 handheldLCD(float2 position, half4 color, float2 source, float2 display, float correction, float lcd) {
    half3 c = color.rgb;
    if (correction > 0.5) {
        // Mild LCD gamut approximation, not a claim of calibrated device reproduction.
        c = half3(dot(c, half3(.82,.12,.06)), dot(c, half3(.08,.84,.08)), dot(c, half3(.12,.10,.78)));
    }
    if (lcd > 0.5) {
        float2 pixel = fract(position * source / max(display, float2(1)));
        half grid = (pixel.x < .08 || pixel.y < .08) ? half(.82) : half(1);
        c *= grid;
    }
    return half4(c, color.a);
}
