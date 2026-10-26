import Foundation

@MainActor extension GameSession {
    func diagnosticText(fps: Double, outputFPS: Double, coreMS: Double) -> String {
        let core = dstv_is_3ds() == 1 ? "Azahar" : (dstv_is_psp() == 1 ? "PPSSPP" : (dstv_is_dust() == 1 ? "Dust" : (dstv_is_desmume() == 1 ? "DeSmuME" : (game.system == .nintendoDS ? "melonDS" : "mGBA"))))
        let renderer = dstv_is_3ds_native_metal() == 1 ? (dstv_is_3ds_hybrid() == 1 ? "Native Metal prototype / GPU vertices with CPU geometry fallback / explicit Vulkan fallback / 1×" : "Native Metal prototype / GPU vertices with CPU geometry fallback / explicit software fallback / 1×") : (dstv_is_3ds() == 1 || dstv_is_psp() == 1) ? "Vulkan via MoltenVK / Metal" : ((dstv_is_dust() == 1 || dstv_ds_gpu_renderer_active() == 1) ? "Metal GPU" : "CPU core rendering / Metal presentation")
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Development"
        return """
        DualScreenTV \(version) · \(Date().formatted(date: .abbreviated, time: .shortened))
        \(game.title) · \(game.system.title)
        Core: \(core) · JIT disabled
        Renderer: \(renderer)
        Metal draws: \(dstv_3ds_metal_native_batches()) native · \(dstv_3ds_metal_fallback_batches()) \(dstv_is_3ds_hybrid() == 1 ? "Vulkan" : "software") fallback
        Output size: \(dstv_top_frame_width()) × \(dstv_top_frame_height())
        Emulated FPS: \(String(format: "%.1f", fps)) · Output FPS: \(String(format: "%.1f", outputFPS))
        Core work: \(String(format: "%.1f", coreMS)) ms per tick
        Audio underruns: \(dstv_audio_underruns()) · Dropped samples: \(dstv_audio_dropped_frames())
        Save states: \(states == nil ? "Unavailable in this integration" : "Available; exact core version required")
        tvOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        """
    }
}
