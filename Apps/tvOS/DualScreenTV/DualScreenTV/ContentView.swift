import SwiftUI
import UIKit
import ImageIO
import Foundation
import CoreGraphics
import Combine

struct ContentView: View {

    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var controller: ControllerInput
    @ObservedObject var settings: AppSettings
    @StateObject private var audio = AudioPlayback()
    @State private var runtime=EmulationPresentationRuntime()
    @State private var screenImage: CGImage?
    @State private var displayedFrameCount: UInt64 = 0
    @State private var didSmokeCheck = false
    @State private var smokeScreenStage = 0
    @State private var paused = false
    @State private var settingsOpenFailed = false
    @State private var pairingInMenu = false
    @State private var saveMenu = false
    @State private var supportMenu = false
    @State private var publishedPausedConnection = false
    @State private var fastForwardToggled = false
    @State private var wantsAudio: Bool?
    @State private var frameWorkMS = 0.0
    @State private var presentationMS = 0.0
    @State private var actionMessage: String?
    @State private var messageUntil = 0.0
    @State private var measuredOutputFPS = 0.0
    @State private var lastReportTime = Date.distantPast
    @State private var lastOutputFrames: UInt64 = 0
    @State private var measuredFPS = 0.0
    @State private var lastFPSUpdate = ProcessInfo.processInfo.systemUptime
    @State private var lastFPSFrames: UInt64 = 0
    #if DEBUG
    @State private var smokeCaptureStage = 0
    @State private var smokeGPUStart: UInt64?
    @State private var smokeGPUWidth: UInt32 = 0
    @State private var smokeGPUBenchmarked = false
    @State private var performanceOriginal: Data?
    @State private var performanceStart: Double?
    @State private var performanceTicks: UInt64 = 0
    @State private var performanceOutput: UInt64 = 0
    @State private var performanceComplete = false
    #endif

    @ObservedObject var session: GameSession
    let onExit: () -> Void
    private let frameTimer = Timer.publish(every: 1.0 / 59.898308, on: .main, in: .common).autoconnect()

    private static func makeScreenImage(screen: DSScreen, enhancement: ImageEnhancement)
        -> CGImage?
    {
        guard let framePointer =
            (screen == .top ? dstv_top_framebuffer() : dstv_bottom_framebuffer())
        else {
            return nil
        }

        let width =
            Int(screen == .top ? dstv_top_frame_width() : dstv_bottom_frame_width())

        let height =
            Int(screen == .top ? dstv_top_frame_height() : dstv_bottom_frame_height())

        let pitch =
            Int(screen == .top ? dstv_top_frame_pitch() : dstv_bottom_frame_pitch())

        guard
            width > 0,
            height > 0,
            pitch > 0
        else {
            return nil
        }

        var outputWidth = width
        var outputHeight = height
        var outputPitch = pitch
        let frameData: Data
        // Higher-resolution 3D already supplies detail; avoid stacking pixel-art
        // enlargement onto it (and bound presentation allocations).
        let factor = width > 400 || height > 240 ? 1 : enhancement.factor
        if factor > 1 {
            outputWidth *= factor
            outputHeight *= factor
            outputPitch = outputWidth * 4
            var scaled = Data(count: outputPitch * outputHeight)
            let result = scaled.withUnsafeMutableBytes {
                dstv_enhance_pixels(framePointer, pitch * height, UInt32(width), UInt32(height),
                                    UInt32(pitch), UInt32(factor), $0.baseAddress, $0.count)
            }
            guard result == 1 else { return makeScreenImage(screen: screen, enhancement: .off) }
            frameData = scaled
        } else {
            frameData = Data(bytes: framePointer, count: pitch * height)
        }

        guard let provider =
            CGDataProvider(
                data: frameData as CFData
            )
        else {
            return nil
        }

        let colourSpace =
            CGColorSpaceCreateDeviceRGB()

        let bitmapInfo =
            CGBitmapInfo.byteOrder32Little
                .union(
                    CGBitmapInfo(
                        rawValue:
                            CGImageAlphaInfo
                                .noneSkipFirst
                                .rawValue
                    )
                )

        return CGImage(
            width: outputWidth,
            height: outputHeight,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: outputPitch,
            space: colourSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private static let showDiagnostics = ProcessInfo.processInfo.arguments.contains("-DSTVDiagnostics")

    private var fastForwarding: Bool {
        settings.values.toggleFastForward ? fastForwardToggled : controller.fastForwardHeld
    }
    private var effectiveSpeed: Double {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-DSTVSmokeSpeed"), index + 1 < arguments.count,
           let speed = Double(arguments[index + 1]), [0, 0.5, 1, 1.5, 2, 3, 4].contains(speed) { return speed }
        #endif
        return fastForwarding ? settings.values.fastForwardSpeed : settings.values.normalSpeed
    }
    private func updateAudio(forceRestart: Bool = false) {
        audio.setStallReserve(dstv_is_3ds() == 1 || dstv_is_single_screen() == 1 || (dstv_is_desmume() == 1 && settings.values.dsPresentationRate == 30) || dstv_is_dust() == 1, sampleRate: dstv_sample_rate())
        let active = scenePhase == .active && session.states?.failedRecovery != true && session.states?.loading != true && !paused && !controller.quickMenuVisible && effectiveSpeed == 1 && session.loaded
        audio.setMixWithOtherAudio(settings.values.mixWithOtherAudio)
        audio.setVolume(percent: settings.values.volume, muted: settings.values.muted)
        if forceRestart || wantsAudio != active {
            if forceRestart && wantsAudio == true { audio.setActive(false, sampleRate: dstv_sample_rate()) }
            audio.setActive(active, sampleRate: dstv_sample_rate())
            wantsAudio = active
        }
        dstv_set_audio_enabled(active ? 1 : 0)
    }
    private func showMessage(_ message: String) {
        actionMessage = message
        messageUntil = ProcessInfo.processInfo.systemUptime + 4
        print(message)
    }

    private var gamePresentation: ScreenPresentation {
        var result = settings.values.presentation(for: displayScreen)
        if !session.game.system.dualScreen && session.game.system != .psp {
            result.integerScale = settings.values.gbIntegerScale
            result.filtering = settings.values.gbSmoothing ? .linear : .nearest
            result.mode = settings.values.gbDisplayMode
            result.zoom = settings.values.gbOverscanPercent
        }
        return result
    }
    private var displayScreen: DSScreen { session.game.system.dualScreen ? settings.values.screen : .top }
    private var nativeScreenSize: CGSize {
        let width = displayScreen == .top ? dstv_top_frame_width() : dstv_bottom_frame_width()
        return CGSize(width: Int(width), height: Int(dstv_top_frame_height()))
    }
    private func shouldLogFrames(before: UInt64, after: UInt64) -> Bool {
        if dstv_is_3ds() == 1 && (before == 0 || before / 60 != after / 60) { return true }
        return (before < 120 && after >= 120) || before / 600 != after / 600
    }
    private func closeQuickMenu() { saveMenu = false; supportMenu = false; controller.quickMenuVisible = false }
    private func saveState(_ slot: Int) {
        guard let states = session.states else { showMessage("Save states aren't available for this core yet"); return }
        let thumbnail = screenImage.flatMap { UIImage(cgImage: $0).pngData() }
        states.save(slot: slot, thumbnail: thumbnail) { showMessage($0) }
    }
    private func loadState(_ slot: Int) {
        guard let states = session.states else { showMessage("Save states aren't available for this core yet"); return }
        states.load(slot: slot, beforeRestore: { session.saves?.flush(); session.clockSave?.flush() }, afterRestore: {
            if states.failedRecovery { session.saves?.protectAfterFailedState(); session.clockSave?.protectAfterFailedState() }
            else { session.saves?.acceptStateBaseline(); session.clockSave?.acceptStateBaseline() }
            runtime.pacer.reset()
        }) { message in showMessage(message); updateAudio(forceRestart: true) }
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else {
            settingsOpenFailed = true
            return
        }
        // Keep the game and quick menu paused while Settings is foregrounded.
        // Existing activation handling reloads preferences when the user returns.
        Task { @MainActor in
            if !(await UIApplication.shared.open(url)) { settingsOpenFailed = true }
        }
    }


    var body: some View {
        ZStack(alignment: .bottomTrailing) {

            Color.black
                .ignoresSafeArea()

            if let screenImage {
                GeometryReader { geometry in
                    let presentation = gamePresentation
                    let size = presentation.imageSize(in: geometry.size, source: nativeScreenSize)
                    Image(decorative: screenImage, scale: 1.0)
                        .resizable()
                        .interpolation(presentation.filtering == .nearest ? .none : .low)
                        .frame(width: size.width, height: size.height)
                        .modifier(HandheldEffects(enabled: !session.game.system.dualScreen && session.game.system != .psp, source: nativeScreenSize, display: size))
                        .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                        .onAppear {
                            #if DEBUG
                            print("TV viewport: \(geometry.size), screen: \(displayScreen.rawValue), mode: \(presentation.mode.rawValue), enhancement: \(presentation.enhancement.rawValue)")
                            #endif
                        }
                        .onChange(of: geometry.size) { size in
                            #if DEBUG
                            print("TV viewport resized: \(size)")
                            #endif
                        }
                }
                .clipped()
                .ignoresSafeArea()

            } else {
                VStack(spacing: 20) {
                    Text("DualScreenTV")
                        .font(.largeTitle)

                    Text(session.status)
                        .font(.title2)

                    if session.loaded {
                        Text(displayScreen == .bottom ? "Waiting for the bottom screen..." : "Starting emulator...")
                    }
                }
                .foregroundColor(.white)
            }

            VStack(alignment: .trailing, spacing: 4) {
                if paused || session.states?.failedRecovery == true {
                    Text("Paused")
                    Button("Return to Library") {
                        guard session.states?.busy != true else { showMessage("Wait for the save operation to finish"); return }
                        onExit()
                    }
                }
                if fastForwarding { Text("Fast Forward") }
                if let actionMessage { Text(actionMessage) }
                if let warning = session.warning ?? session.saves?.warning {
                    Text(warning).foregroundColor(.yellow)
                }
                if audio.hasFailed {
                    Text("Audio unavailable; see development log.").foregroundColor(.yellow)
                }
                if Self.showDiagnostics || settings.values.showFrames {
                    Text("Frames: \(displayedFrameCount)")
                }
                if Self.showDiagnostics || settings.values.showFPS {
                    Text(String(format: "Emulated FPS: %.1f", measuredFPS))
                    if dstv_is_3ds() == 1 || dstv_is_desmume() == 1 || dstv_is_dust() == 1 { Text(String(format: "Output FPS: %.1f", measuredOutputFPS)) }
                }
                if Self.showDiagnostics || settings.values.showPerformance {
                    Text(String(format: "Core work: %.1f ms / tick · Speed: %@", frameWorkMS, effectiveSpeed == 0 ? "Unlimited" : String(format: "%.1fx", effectiveSpeed)))
                    Text(String(format: "Presentation: %.1f ms · Enhancement: %dx", presentationMS, dstv_top_frame_height() > 240 ? 1 : settings.values.presentation(for: displayScreen).enhancement.factor))
                    if dstv_is_psp() == 1 { Text("PSP: \(dstv_top_frame_width())×\(dstv_top_frame_height()) · Vulkan / Metal · IR interpreter (no JIT)") }
                    if dstv_is_3ds() == 1 { Text("3DS internal resolution: \(dstv_top_frame_width() / 400)× · Output target: \(settings.values.threeDSPresentationRate) FPS") }
                    if dstv_is_3ds_native_metal() == 1 {
                        Text(dstv_is_3ds_hybrid() == 1
                            ? "Metal + Vulkan · 1× · Metal draws \(dstv_3ds_metal_native_batches()) / Vulkan fallback \(dstv_3ds_metal_fallback_batches())"
                            : "Native Metal · \(dstv_top_frame_width() / 400)× · GPU vertex batches \(dstv_3ds_metal_vertex_batches()) · Metal draws \(dstv_3ds_metal_native_batches()) / software fallback \(dstv_3ds_metal_fallback_batches())")
                    }
                    Text("Audio underruns: \(dstv_audio_underruns()) / drops: \(dstv_audio_dropped_frames())")
                }
                if (Self.showDiagnostics || settings.values.showFPS || settings.values.showPerformance) && dstv_is_dust() == 1 { Text("DS internal resolution: \(dstv_top_frame_width() / 256)× output · \(dstv_ds_internal_resolution())× 3D · Dust Metal GPU · Output target: \(settings.values.dsPresentationRate) FPS") }
                if (Self.showDiagnostics || settings.values.showFPS || settings.values.showPerformance) && dstv_is_desmume() == 1 { Text("DS internal resolution: \(dstv_top_frame_width() / 256)× · \(settings.values.dsAutomaticResolution ? "Auto (up to \(settings.values.dsResolution)×)" : "Fixed") · Target: \(settings.values.dsPresentationRate) FPS · \(dstv_ds_gpu_renderer_active() == 1 ? "Metal GPU fragments" : "CPU renderer")") }
            }
            .font(.caption2)
            .foregroundColor(.white)
            // White difference blending inverts the game pixels behind the HUD.
            .blendMode(.difference)
            .padding(30)

            if controller.quickMenuVisible {
                Color.black.opacity(0.85).ignoresSafeArea()
                VStack(spacing: 24) {
                    if saveMenu, let states = session.states {
                        SaveStateView(gameTitle: session.game.title, manager: states, save: saveState, load: loadState) { saveMenu = false }
                    } else if supportMenu {
                        GameSupportView(report: session.diagnosticText(fps: measuredFPS, outputFPS: measuredOutputFPS, coreMS: frameWorkMS), isPSP: session.game.system == .psp) { supportMenu = false }
                    } else if pairingInMenu {
                        Text("Link iPad Companion").font(.title.bold())
                        Text("On iPad, select this Apple TV and enter:")
                        Text(session.companion.code).font(.system(size: 60, weight: .bold, design: .monospaced))
                        CompanionMenuStatus(model: session.companion)
                        Button("Resume Game") { closeQuickMenu() }
                        Button("Back to Quick Menu") { pairingInMenu = false }
                    } else {
                        ScrollView { VStack(spacing: 16) {
                        Text("Game Paused").font(.title.bold())
                        Button("Resume Game") { closeQuickMenu() }
                        if session.game.system.dualScreen {
                        Button("Link iPad Companion") {
                            session.companion.start(); session.companion.publishGameFrame(); pairingInMenu = true
                        }
                        Button(displayScreen == .top ? "Swap Screens (Bottom on TV)" : "Swap Screens (Top on TV)") { settings.toggleScreen() }
                        }
                        Button(session.states == nil ? "Save States · Unavailable" : "Save States") {
                            if session.states != nil { saveMenu = true }
                            else { showMessage("This core uses in-game saves. Browse or export them from Game Details → Browse Save Files.") }
                        }
                        Button("Controller & Game Info") { supportMenu = true }
                        Button("Open App Settings") { openAppSettings() }
                        Button("Return to Library") {
                            guard session.states?.busy != true else { return }
                            onExit()
                        }
                        Text("Press LB + RB + A together to open this menu.").font(.caption)
                        GameVolumeControl(volume: settings.values.muted ? 0 : settings.values.volume) { value in
                            settings.setGameVolume(value)
                            audio.setVolume(percent: settings.values.volume, muted: settings.values.muted)
                        }
                        }.padding(30) }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .foregroundColor(.white)
                .overlay(alignment: .topTrailing) {
                    if let actionMessage, ProcessInfo.processInfo.systemUptime < messageUntil {
                        Text(actionMessage).font(.caption).padding(18).background(.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 16)).padding(20)
                    }
                }
                .onExitCommand { closeQuickMenu() }
            }
        }
        // Consume gameplay Back commands even when a long press does not
        // qualify as a UIKit tap. Exiting a game is an explicit quick-menu action.
        .onExitCommand { if controller.quickMenuVisible { closeQuickMenu() } }
        .alert("Couldn’t Open Settings", isPresented: $settingsOpenFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Open Apple TV Settings → Apps → DualScreenTV. Your game is still paused.")
        }
        .onAppear {
            // Global bridge counters survive core reinitialization; measure only
            // this session rather than counting earlier games in the first FPS sample.
            displayedFrameCount = dstv_total_video_frames()
            lastFPSFrames = dstv_total_core_ticks()
            lastOutputFrames = displayedFrameCount
            lastFPSUpdate = ProcessInfo.processInfo.systemUptime
            settings.reload()
            session.companion.tvScreen = displayScreen
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-DSTV3DSSmoke") { session.companion.start() }
            if ProcessInfo.processInfo.arguments.contains("-DSTVDustBenchmark") {
                paused = true
                showMessage("Testing alternative DS GPU core…")
                DustBenchmark.run(rom: session.debugROMURL,
                    shift: ProcessInfo.processInfo.arguments.contains("-DSTVDust8x") ? 3 : 2) { message in
                    showMessage(message); paused = false
                    updateAudio(forceRestart: true); runtime.pacer.reset()
                }
            }
            #endif
            updateAudio()
        }
        .onDisappear {
            #if DEBUG
            if let original = performanceOriginal {
                _ = original.withUnsafeBytes { dstv_load_state($0.baseAddress, $0.count) }
                performanceOriginal = nil
            }
            #endif
            audio.setActive(false, sampleRate: dstv_sample_rate())
            dstv_set_audio_enabled(0)
            controller.clear()
            session.stop()
        }
        .onChange(of: controller.quickMenuVisible) { visible in
            publishedPausedConnection = false
            controller.clear()
            dstv_set_touch(0, 0, 0); dstv_set_companion_buttons(0)
            runtime.pacer.reset(); updateAudio()
            if !visible { pairingInMenu = false }
        }
        .onChange(of: settings.values) { values in
            if dstv_is_3ds() == 1 { dstv_set_metal_surface_cache(values.threeDSMetalSurfaceCache ? 1 : 0) }
            runtime.lastTVRevision=nil;runtime.lastCompanionRevision=nil
            session.companion.tvScreen = values.screen
            session.companion.publishGameFrame()
            dstv_set_touch(0, 0, 0)
            // Screen selection and presentation apply even while paused.
            screenImage = Self.makeScreenImage(screen: displayScreen,
                enhancement: values.presentation(for: values.screen).enhancement)
            #if DEBUG
            print("TV screen selected: \(values.screen.rawValue), top available=\(dstv_top_framebuffer() != nil), bottom available=\(dstv_bottom_framebuffer() != nil)")
            #endif
            updateAudio()
        }
        .onChange(of: settings.values.normalSpeed) { _ in runtime.pacer.reset() }
        .onChange(of: settings.values.fastForwardSpeed) { _ in runtime.pacer.reset() }
        .onChange(of: settings.values.toggleFastForward) { _ in fastForwardToggled = false; runtime.pacer.reset() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { settings.reload() }
            if phase != .active { session.saves?.flush(); session.clockSave?.flush(); session.states?.flush() }
            controller.clear()
            dstv_set_touch(0, 0, 0); dstv_set_companion_buttons(0)
            fastForwardToggled = false
            runtime.pacer.reset()
            lastFPSUpdate = ProcessInfo.processInfo.systemUptime
            lastFPSFrames = dstv_total_core_ticks()
            lastOutputFrames = displayedFrameCount
            updateAudio()
        }
        .onReceive(frameTimer) { _ in
            guard scenePhase == .active, session.loaded else { return }
            if Date().timeIntervalSince(lastReportTime) >= 10 {
                lastReportTime = Date()
                session.latestDiagnosticReport = session.diagnosticText(fps: measuredFPS, outputFPS: measuredOutputFPS, coreMS: frameWorkMS)
            }
            session.companion.publishMenu(LinkMenuState(active: true,
                paused: paused || controller.quickMenuVisible, dualScreen: session.game.system.dualScreen,
                volume: UInt8(settings.values.muted ? 0 : settings.values.volume), bottomOnTV: displayScreen == .bottom))
            for command in session.companion.takeMenuCommands() {
                switch command.action {
                case .pause: controller.quickMenuVisible = true
                case .resume: paused = false; closeQuickMenu()
                case .swapScreens:
                    if session.game.system.dualScreen { settings.toggleScreen() }
                case .openSettings: controller.quickMenuVisible = true; openAppSettings()
                case .returnToLibrary:
                    guard session.states?.busy != true else { continue }
                    session.companion.endGame(); onExit(); return
                case .saveState: saveState(Int(command.value))
                case .loadState: loadState(Int(command.value))
                case .volume:
                    settings.setGameVolume(Int(command.value))
                    audio.setVolume(percent: settings.values.volume, muted: settings.values.muted)
                }
            }
            let now = ProcessInfo.processInfo.systemUptime
            #if DEBUG
            if dstv_is_dust() == 1 && ProcessInfo.processInfo.arguments.contains("-DSTVDustPlaybackTest") && !performanceComplete {
                if performanceStart == nil {
                    performanceStart = now; performanceTicks = dstv_total_core_ticks(); performanceOutput = dstv_total_video_frames()
                    print("Dust timed playback started")
                } else if let start = performanceStart, now - start >= 180 {
                    let elapsed = now - start
                    print("Dust timed playback: \(elapsed)s, guestFPS=\(Double(dstv_total_core_ticks() - performanceTicks) / elapsed), outputFPS=\(Double(dstv_total_video_frames() - performanceOutput) / elapsed), underruns=\(dstv_audio_underruns()), drops=\(dstv_audio_dropped_frames())")
                    performanceComplete = true
                }
            }
            // Timed playback through the ordinary scheduler/audio path. Keep
            // original guest RAM and restore before normal exit or test end.
            if ProcessInfo.processInfo.arguments.contains("-DSTVDSPerformanceFixture") && dstv_is_desmume() == 1 && !performanceComplete {
                if performanceStart == nil {
                    performanceComplete = true
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ds-performance-\(session.game.id).state")
                    if let fixture = try? Data(contentsOf: url) {
                        var original = Data(count: dstv_state_size())
                        if !original.isEmpty && original.withUnsafeMutableBytes({ dstv_save_state($0.baseAddress, $0.count) }) == 1 && fixture.withUnsafeBytes({ dstv_load_state($0.baseAddress, $0.count) }) == 1 {
                            performanceOriginal = original; performanceStart = now
                            performanceTicks = dstv_total_core_ticks(); performanceOutput = dstv_total_video_frames()
                            performanceComplete = false; updateAudio(forceRestart: true); runtime.pacer.reset()
                            print("DS timed playback started: \(settings.values.dsResolution)×, \(settings.values.dsPresentationRate) FPS target")
                        }
                    }
                } else if let start = performanceStart, now - start >= (ProcessInfo.processInfo.arguments.contains("-DSTVDSLongPerformanceFixture") ? 180 : 45), let original = performanceOriginal {
                    print("DS timed playback result: guest=\(Double(dstv_total_core_ticks() - performanceTicks)/(now-start)) FPS, output=\(Double(dstv_total_video_frames() - performanceOutput)/(now-start)) FPS, underruns=\(dstv_audio_underruns()), drops=\(dstv_audio_dropped_frames())")
                    for screen in [DSScreen.top, .bottom] {
                        if let image = Self.makeScreenImage(screen: screen, enhancement: .off) {
                            let url = FileManager.default.temporaryDirectory.appendingPathComponent("ds-performance-\(screen.rawValue).png")
                            if let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
                                CGImageDestinationAddImage(destination, image, nil)
                                _ = CGImageDestinationFinalize(destination)
                            }
                        }
                    }
                    _ = original.withUnsafeBytes { dstv_load_state($0.baseAddress, $0.count) }
                    performanceOriginal = nil; performanceComplete = true
                    updateAudio(forceRestart: true); runtime.pacer.reset()
                }
            }
            #endif
            if now >= messageUntil { actionMessage = nil }
            guard !controller.quickMenuVisible else {
                // A newly paired iPad can show the paused game before Resume.
                if !session.companion.connected { publishedPausedConnection = false }
                else if !publishedPausedConnection {
                    session.companion.publishGameFrame(); publishedPausedConnection = true
                }
                runtime.pacer.reset(); return
            }
            if dstv_is_psp() == 1 {
                var factor = settings.values.pspResolution
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-DSTVSmokePSPResolutionCycle") {
                    let sequence = [1, 2, 3, 4, 1]
                    factor = sequence[min(sequence.count - 1, Int(dstv_total_core_ticks() / 180))]
                    if dstv_total_core_ticks() % 180 == 120 {
                        print("PSP live resolution: requested=\(factor)x actual=\(dstv_top_frame_width())x\(dstv_top_frame_height()) tick=\(dstv_total_core_ticks())")
                    }
                }
                #endif
                dstv_set_psp_options(UInt32(factor), UInt32(["Auto", "Nearest", "Linear"].firstIndex(of: settings.values.pspFiltering) ?? 0), UInt32(["disabled", "2x", "4x", "8x", "16x"].firstIndex(of: settings.values.pspAnisotropic) ?? 0))
            }
            dstv_set_presentation_rate(UInt32(settings.values.threeDSPresentationRate))
            if dstv_is_3ds() == 1 {
                var factor = settings.values.threeDSResolution
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-DSTVSmokeResolutionCycle") {
                    let sequence = [2, 3, 1, 4, 2]
                    factor = sequence[min(sequence.count - 1, Int(dstv_total_core_ticks() / 180))]
                    if factor != Int(dstv_top_frame_width() / 400) {
                        print("Live resolution smoke: ticks=\(dstv_total_core_ticks()), requested=\(factor)×")
                    }
                }
                #endif
                dstv_set_3ds_resolution(UInt32(factor))
            }
            if dstv_is_dust() == 1 {
                dstv_set_ds_output_limit(settings.values.dsDustOutputLimit ? 4 : 8)
                var factor = settings.values.dsResolution
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-DSTVDustResolutionCycle") {
                    let stages = [4, 8, 2, 4]
                    factor = stages[min(3, Int(dstv_total_core_ticks() / 7200))]
                }
                if ProcessInfo.processInfo.arguments.contains("-DSTVDustIntegerResolutionCycle") {
                    let stages = [5, 6, 7, 4]
                    factor = stages[min(3, Int(dstv_total_core_ticks() / 900))]
                    dstv_set_ds_output_limit(8)
                }
                #endif
                dstv_set_ds_resolution(UInt32(factor))
                dstv_set_ds_presentation_rate(UInt32(settings.values.dsPresentationRate))
            }
            if dstv_is_desmume() == 1 {
                var factor = runtime.dsResolutionController.configure(maximum: settings.values.dsResolution, automatic: settings.values.dsAutomaticResolution)
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-DSTVSmokeDSGPUCycle") && dstv_ds_gpu_renderer_active() == 1 {
                    if smokeGPUStart == nil { smokeGPUStart = dstv_total_core_ticks() }
                    let sequence = [4, 6, 8, 2, 4]
                    factor = sequence[min(sequence.count - 1, Int((dstv_total_core_ticks() - (smokeGPUStart ?? 0)) / 180))]
                    if factor != Int(dstv_top_frame_width() / 256) {
                        print("DS GPU cycle: requested=\(factor)×")
                    }
                }
                if ProcessInfo.processInfo.arguments.contains("-DSTVSmokeDSResolutionCycle") {
                    let sequence = [2, 4, 6, 8, 1, 2]
                    factor = sequence[min(sequence.count - 1, Int(dstv_total_core_ticks() / 180))]
                    if factor != Int(dstv_top_frame_width() / 256) {
                        print("DS resolution smoke: ticks=\(dstv_total_core_ticks()), requested=\(factor)×")
                    }
                }
                #endif
                dstv_set_ds_presentation_rate(UInt32(settings.values.dsPresentationRate))
                dstv_set_ds_gpu_renderer(settings.values.dsGPURenderer ? 1 : 0)
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-DSTVDSPerformanceFixture"), factor != Int(dstv_top_frame_width() / 256) {
                    print("DS automatic scale: \(factor)×, previous core work \(frameWorkMS) ms, elapsed \(now - (performanceStart ?? now)) s")
                }
                #endif
                dstv_set_ds_resolution(UInt32(factor))
            }
            controller.poll()
            guard !controller.quickMenuVisible else { updateAudio(); runtime.pacer.reset(); return }
            #if DEBUG
            // Opt-in presentation smoke check. Toggle twice so the original
            // persisted screen preference is restored by the second checkpoint.
            if ProcessInfo.processInfo.arguments.contains("-DSTVSmokeScreens") &&
                ((smokeScreenStage == 0 && displayedFrameCount >= 120) ||
                 (smokeScreenStage == 1 && displayedFrameCount >= 600)) {
                settings.toggleScreen()
                smokeScreenStage += 1
                if let top = dstv_top_framebuffer(), let bottom = dstv_bottom_framebuffer() {
                    let distinct = Data(bytes: top, count: 256 * 192 * 4) != Data(bytes: bottom, count: 256 * 192 * 4)
                    print("Screen smoke: stage=\(smokeScreenStage), selected=\(displayScreen.rawValue), distinct framebuffers=\(distinct)")
                }
            }
            #endif
            if session.game.system.dualScreen && (controller.screenSwitchPressed || controller.actionEdges & InputBinding.switchScreen.actionMask != 0) {
                settings.toggleScreen()
                showMessage(displayScreen == .top ? "TV: Top · Companion: Bottom" : "TV: Bottom · Companion: Top")
            }
            if controller.actionEdges & InputBinding.fastForward.actionMask != 0 && settings.values.toggleFastForward {
                fastForwardToggled.toggle()
            }
            if controller.actionEdges & InputBinding.pause.actionMask != 0 {
                paused.toggle()
                runtime.pacer.reset()
            }
            if controller.actionEdges & InputBinding.reset.actionMask != 0 && session.states?.loading != true {
                session.saves?.flush(); session.clockSave?.flush()
                audio.setActive(false, sampleRate: dstv_sample_rate())
                wantsAudio = false
                dstv_set_audio_enabled(0)
                if dstv_reset_game() == 1 { showMessage("Game reset") }
                runtime.pacer.reset()
            }
            if controller.actionEdges & InputBinding.saveState.actionMask != 0 { saveState(settings.values.stateSlot) }
            if controller.actionEdges & InputBinding.loadState.actionMask != 0 { loadState(settings.values.stateSlot) }
            updateAudio()
            guard !paused && session.states?.failedRecovery != true && session.states?.loading != true else { dstv_set_touch(0, 0, 0); dstv_set_companion_buttons(0); runtime.pacer.reset(); return }
            dstv_set_companion_buttons(session.companion.latestButtons)
            let companionStick = session.companion.latestAnalog
            if (dstv_is_3ds() == 1 || dstv_is_psp() == 1), companionStick.x != 0 || companionStick.y != 0 {
                dstv_set_analog(companionStick.x, companionStick.y, 0, 0)
            }
            let touch = session.companion.latestTouch
            dstv_set_touch(touch.pressed ? 1 : 0, touch.x, touch.y)
            #if DEBUG
            // Explicit ORAS device validation only: advance the title/Continue
            // prompts, then release all inputs. Never used by normal launches.
            if dstv_is_3ds() == 1 && ProcessInfo.processInfo.arguments.contains("-DSTVORASContinue") {
                let tick = dstv_total_core_ticks()
                dstv_set_buttons(tick > 180 && tick < 1800 && tick % 120 < 8 ? 1 << 8 : 0)
                if ProcessInfo.processInfo.arguments.contains("-DSTVORASWalk") && tick >= 2000 && tick < 2180 { dstv_set_buttons(1 << 5) }
                if ProcessInfo.processInfo.arguments.contains("-DSTVORASBenchmarkRoute"), tick >= 2000 {
                    // Identical emulated input durations across renderers, even
                    // if their wall-clock performance differs. No save writes.
                    let route: [(UInt64, UInt16)] = [(60, 1 << 7), (180, 1 << 5), (120, 1 << 7), (120, 1 << 5), (78, 1 << 6), (120, 1 << 5), (48, 1 << 7), (60, 1 << 5)]
                    var remaining = tick - 2000
                    var buttons: UInt16 = 0
                    for (duration, mask) in route {
                        if remaining < duration { buttons = mask; break }
                        remaining -= duration
                    }
                    dstv_set_buttons(buttons)
                }
            }
            if dstv_is_dust() == 1 && ProcessInfo.processInfo.arguments.contains("-DSTVDustAutoplay") {
                let tick = dstv_total_core_ticks()
                dstv_set_buttons(tick > 6500 ? (tick % 600 >= 500 && tick % 600 < 512 ? 1 << 3 : (tick % 120 < 12 ? 1 << 8 : 0)) : 0)
            }
            if dstv_is_dust() == 1 && ProcessInfo.processInfo.arguments.contains("-DSTVDustSnapshots") {
                let stage = Int(dstv_total_core_ticks() / 1800)
                if stage > smokeCaptureStage {
                    smokeCaptureStage = stage
                    for screen in [DSScreen.top, .bottom] {
                        if let image = Self.makeScreenImage(screen: screen, enhancement: .off) {
                            let url = FileManager.default.temporaryDirectory.appendingPathComponent("dust-\(stage)-\(screen.rawValue).png")
                            DispatchQueue.global(qos: .utility).async {
                            if let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
                                CGImageDestinationAddImage(destination, image, nil)
                                print("Dust snapshot: \(stage) \(screen.rawValue) \(image.width)x\(image.height), written=\(CGImageDestinationFinalize(destination))")
                            }
                            }
                        }
                    }
                }
            }
            #endif
            let frames = runtime.pacer.framesDue(now: now, fps: dstv_frames_per_second(), speed: effectiveSpeed, catchUp: dstv_is_single_screen() == 1 || dstv_is_3ds() == 1 || dstv_is_desmume() == 1 || dstv_is_dust() == 1, debtLimit: (dstv_is_dust() == 1 || dstv_is_3ds() == 1) ? 4 : 2)
            let coreStart = ProcessInfo.processInfo.systemUptime
            let beforeTicks = dstv_total_core_ticks()
            let before = dstv_total_video_frames()
            for index in 0..<frames {
                // Bound catch-up to two guest ticks and one small work budget.
                // Retain unexecuted normal-speed credit; shader stalls never
                // enqueue an unbounded burst of work.
                let catchingUp = (dstv_is_single_screen() == 1 || dstv_is_3ds() == 1 || dstv_is_desmume() == 1 || dstv_is_dust() == 1) && effectiveSpeed == 1
                let budget = catchingUp ? 0.016 : 0.008
                if index > 0 && ProcessInfo.processInfo.systemUptime - now >= budget {
                    if catchingUp { runtime.pacer.deferFrames(frames - index, debtLimit: (dstv_is_dust() == 1 || dstv_is_3ds() == 1) ? 4 : 2) }
                    break
                }
                let tickStart = Self.showDiagnostics ? ProcessInfo.processInfo.systemUptime : 0
                guard dstv_run_one_frame() == 1 else { break }
                if Self.showDiagnostics {
                    let tickMS = (ProcessInfo.processInfo.systemUptime - tickStart) * 1000
                    runtime.profileTickCount += 1
                    if tickMS > 16.667 { runtime.profileSlowTicks += 1 }
                    runtime.profileMaxTickMS = max(runtime.profileMaxTickMS, tickMS)
                }
            }
            if Self.showDiagnostics {
                if let start = runtime.profileWindowStart {
                    if now - start >= 5 {
                        let underruns = dstv_audio_underruns(), drops = dstv_audio_dropped_frames()
                        let underrunDelta = underruns >= runtime.profileUnderruns ? underruns - runtime.profileUnderruns : underruns
                        let dropDelta = drops >= runtime.profileDrops ? drops - runtime.profileDrops : drops
                        print(String(format: "Audio/core window: uptime=%.3f seconds=%.2f ticks=%d slow_ticks_16ms=%d max_tick_ms=%.3f underruns=%llu drops=%llu", now, now - start, runtime.profileTickCount, runtime.profileSlowTicks, runtime.profileMaxTickMS, underrunDelta, dropDelta))
                        runtime.profileWindowStart = now; runtime.profileTickCount = 0; runtime.profileSlowTicks = 0; runtime.profileMaxTickMS = 0
                        runtime.profileUnderruns = underruns; runtime.profileDrops = drops
                    }
                } else {
                    runtime.profileWindowStart = now; runtime.profileUnderruns = dstv_audio_underruns(); runtime.profileDrops = dstv_audio_dropped_frames()
                }
            }
            let coreWorkSeconds = ProcessInfo.processInfo.systemUptime - coreStart
            let executedTicks = Int(dstv_total_core_ticks() - beforeTicks)
            let currentFrameWorkMS = coreWorkSeconds * 1000 / Double(max(1, executedTicks))
            if dstv_is_desmume() == 1 && effectiveSpeed == 1 {
                runtime.dsResolutionController.observe(now: ProcessInfo.processInfo.systemUptime,
                    ticks: executedTicks, workSeconds: coreWorkSeconds)
            } else { runtime.dsResolutionController.resetSamples() }
            // Intermediate callbacks only replace the C framebuffer. Copy once.
            let presentationStart = ProcessInfo.processInfo.systemUptime
            let currentVideoFrameCount=dstv_total_video_frames()
            let revision=dstv_video_revision(displayScreen == .bottom ? 1:0)
            if currentVideoFrameCount != before && runtime.lastTVRevision != revision,
               let image=Self.makeScreenImage(screen:displayScreen,enhancement:settings.values.presentation(for:displayScreen).enhancement) {
                screenImage=image;runtime.lastTVRevision=revision
            }
            let connected=session.companion.connected
            let companionRevision=dstv_video_revision(displayScreen == .bottom ? 0:1)
            if session.game.system.dualScreen && connected && (!runtime.companionWasConnected || runtime.lastCompanionRevision != companionRevision) {
                session.companion.publishGameFrame();runtime.lastCompanionRevision=companionRevision
            }
            runtime.companionWasConnected=connected
            let currentPresentationMS=(ProcessInfo.processInfo.systemUptime-presentationStart)*1000
            if now - lastFPSUpdate >= 1 {
                frameWorkMS=currentFrameWorkMS;presentationMS=currentPresentationMS
                displayedFrameCount=currentVideoFrameCount
                measuredFPS = Double(dstv_total_core_ticks() - lastFPSFrames) / (now - lastFPSUpdate)
                measuredOutputFPS = Double(currentVideoFrameCount - lastOutputFrames) / (now - lastFPSUpdate)
                lastOutputFrames = currentVideoFrameCount
                lastFPSFrames = dstv_total_core_ticks()
                lastFPSUpdate = now
            }
            #if DEBUG
            // Opt-in matched core benchmark. Restore identical RAM before each run,
            // and the original session afterwards; never writes a state or save file.
            if ProcessInfo.processInfo.arguments.contains("-DSTVDSCadenceBenchmark") && dstv_is_desmume() == 1 && !smokeGPUBenchmarked {
                smokeGPUBenchmarked = true
                audio.setActive(false, sampleRate: dstv_sample_rate())
                var original = Data(count: dstv_state_size())
                if !original.isEmpty && original.withUnsafeMutableBytes({ dstv_save_state($0.baseAddress, $0.count) }) == 1 {
                    let fixtureURL = FileManager.default.temporaryDirectory.appendingPathComponent("ds-metal-benchmark.state")
                    let fixture = (try? Data(contentsOf: fixtureURL)) ?? original
                    let factors = ProcessInfo.processInfo.arguments.contains("-DSTVDSCadence8Only") ? [8] : [4, 6]
                    for factor in factors {
                        for rate in [60, 30] {
                            guard fixture.withUnsafeBytes({ dstv_load_state($0.baseAddress, $0.count) }) == 1 else { break }
                            dstv_set_ds_resolution(UInt32(factor))
                            dstv_set_ds_gpu_renderer(1)
                            dstv_set_ds_presentation_rate(UInt32(rate))
                            for _ in 0..<10 { _ = dstv_run_one_frame() }
                            let beforeTicks = dstv_total_core_ticks()
                            let beforeOutput = dstv_total_video_frames()
                            let start = ProcessInfo.processInfo.systemUptime
                            let ticks = factor == 8 ? 30 : 120
                            for _ in 0..<ticks { _ = dstv_run_one_frame() }
                            let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000 / Double(ticks)
                            print("Matched DS cadence benchmark: \(factor)× \(rate) FPS \(elapsed) ms/frame, guest ticks=\(dstv_total_core_ticks() - beforeTicks), output frames=\(dstv_total_video_frames() - beforeOutput)")
                            if rate == 30 {
                                for screen in [DSScreen.top, .bottom] {
                                    if let image = Self.makeScreenImage(screen: screen, enhancement: .off) {
                                        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ds-metal-benchmark-\(factor)x-\(screen.rawValue).png")
                                        if let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
                                            CGImageDestinationAddImage(destination, image, nil)
                                            print("DS Metal benchmark snapshot: \(image.width)x\(image.height), written=\(CGImageDestinationFinalize(destination))")
                                        }
                                    }
                                }
                            }
                        }
                    }
                    _ = original.withUnsafeBytes { dstv_load_state($0.baseAddress, $0.count) }
                    dstv_set_ds_resolution(UInt32(settings.values.dsResolution))
                    dstv_set_ds_presentation_rate(UInt32(settings.values.dsPresentationRate))
                    dstv_set_ds_gpu_renderer(settings.values.dsGPURenderer ? 1 : 0)
                    updateAudio(forceRestart: true)
                    runtime.pacer.reset()
                }
                updateAudio(forceRestart: true)
            }
            if ProcessInfo.processInfo.arguments.contains("-DSTVSmokeDSGPUCycle") && dstv_ds_gpu_renderer_active() == 1 && smokeGPUWidth != dstv_top_frame_width() {
                smokeGPUWidth = dstv_top_frame_width()
                for screen in [DSScreen.top, .bottom] {
                    if let image = Self.makeScreenImage(screen: screen, enhancement: .off) {
                        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ds-metal-\(smokeGPUWidth / 256)x-\(screen.rawValue).png")
                        if let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
                            CGImageDestinationAddImage(destination, image, nil)
                            print("DS Metal snapshot: \(screen.rawValue) \(image.width)x\(image.height), written=\(CGImageDestinationFinalize(destination))")
                        }
                    }
                }
            }
            let captureThresholds: [UInt64] = [120, 240, 600, 1200, 2400, 3600]
            if smokeCaptureStage < captureThresholds.count && currentVideoFrameCount >= captureThresholds[smokeCaptureStage] && ProcessInfo.processInfo.arguments.contains("-DSTV3DSSmoke") {
                smokeCaptureStage += 1
                for screen in [DSScreen.top, .bottom] {
                    if let image = Self.makeScreenImage(screen: screen, enhancement: .off) {
                        let url = FileManager.default.temporaryDirectory.appendingPathComponent("3ds-smoke-" + screen.rawValue + ".png")
                        if let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
                            CGImageDestinationAddImage(destination, image, nil)
                            print("3DS screen snapshot: \(screen.rawValue) \(image.width)x\(image.height), written=\(CGImageDestinationFinalize(destination))")
                        }
                    }
                }
            }
            if !didSmokeCheck && currentVideoFrameCount >= 120 && ProcessInfo.processInfo.arguments.contains("-DSTVSmokeState") {
                didSmokeCheck = true
                audio.setActive(false, sampleRate: dstv_sample_rate())
                wantsAudio = false
                dstv_set_audio_enabled(0)
                if dstv_is_single_screen() == 1, let image = Self.makeScreenImage(screen: .top, enhancement: .off) {
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("single-system-smoke.png")
                    if let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
                        CGImageDestinationAddImage(destination, image, nil)
                        print("Single screen snapshot: \(image.width)x\(image.height), written=\(CGImageDestinationFinalize(destination))")
                    }
                }
                print(CoreSmokeCheck.run())
                session.saves?.acceptStateBaseline(); session.clockSave?.acceptStateBaseline()
                runtime.pacer.reset()
                updateAudio()
            }
            #endif
            session.saves?.poll(); session.clockSave?.poll()
            if Self.showDiagnostics && shouldLogFrames(before: before, after: currentVideoFrameCount) {
                if dstv_is_dust() == 1 { print("Dust actual GPU 3D submissions: \(dstv_ds_gpu_submissions()) · 3D \(dstv_ds_internal_resolution())× / output \(dstv_top_frame_width() / 256)×") }
                if dstv_is_3ds_native_metal() == 1 {
                    print("\(dstv_is_3ds_hybrid() == 1 ? "Metal / Vulkan" : "Native Metal") batches: GPU=\(dstv_3ds_metal_native_batches()), fallback=\(dstv_3ds_metal_fallback_batches())")
                }
                print("Runtime: \(currentVideoFrameCount) video frames, audio underruns \(dstv_audio_underruns()), drops \(dstv_audio_dropped_frames())")
                audio.logTiming()
                print(String(format: "Performance: target=%.1fx, measured=%.1f fps, core=%.1f ms/tick, presentation=%.1f ms, enhancement=%dx", effectiveSpeed, measuredFPS, frameWorkMS, presentationMS, dstv_top_frame_height() > 240 ? 1 : settings.values.presentation(for: displayScreen).enhancement.factor))
            }
        }
    }
}

// Observe connection diagnostics only inside the pairing panel, not each game frame.
private struct CompanionMenuStatus: View {
    @ObservedObject var model: CompanionHostModel
    var body: some View { Text(model.status.message).font(.headline) }
}

// tvOS has no native SwiftUI Slider. A focusable track supports controller
// and remote left/right input, with up/down left to normal focus navigation.
private struct GameVolumeControl: View {
    let volume: Int
    let setVolume: (Int) -> Void
    @FocusState private var focused: Bool

    private func adjust(_ delta: Int) { setVolume(min(100, max(0, volume + delta))) }

    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .frame(width: 28)
            Text("Game Volume").fixedSize()
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.2)).frame(height: 6)
                    Capsule().fill(.white)
                        .frame(width: geometry.size.width * CGFloat(volume) / 100, height: 6)
                    Circle().fill(.white).frame(width: 16, height: 16)
                        .offset(x: (geometry.size.width - 16) * CGFloat(volume) / 100)
                }
                .frame(height: 16)
            }
            .frame(height: 16)
            Text("\(volume)%").monospacedDigit().frame(width: 68, alignment: .trailing)
        }
        .font(.system(size: 22, weight: .medium))
        .lineLimit(1)
        .padding(.horizontal, 20)
        .frame(width: 620, height: 58)
        .background(.white.opacity(focused ? 0.16 : 0.06), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(focused ? 1 : 0.2), lineWidth: focused ? 2 : 1))
        .focusable()
        .focused($focused)
        .onMoveCommand { direction in
            if direction == .left { adjust(-10) }
            if direction == .right { adjust(10) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Game Volume")
        .accessibilityValue("\(volume) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: adjust(10)
            case .decrement: adjust(-10)
            @unknown default: break
            }
        }
    }
}

// Hot scheduler/profiling state has no visual observers. Mutating these fields
// must not invalidate the SwiftUI tree on every emulation callback.
private final class EmulationPresentationRuntime {
    var pacer=FramePacer()
    var dsResolutionController=DSResolutionController()
    var profileWindowStart:Double?
    var profileTickCount=0,profileSlowTicks=0
    var profileMaxTickMS=0.0
    var profileUnderruns:UInt64=0,profileDrops:UInt64=0
    var lastTVRevision:UInt64?,lastCompanionRevision:UInt64?
    var companionWasConnected=false
}
