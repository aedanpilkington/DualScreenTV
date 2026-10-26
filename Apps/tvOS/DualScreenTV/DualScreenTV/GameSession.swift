import Foundation
import Combine

// One owner: 3DS boots on a worker while library actions are locked;
// ownership transfers to the main actor before any frames/input/save operations.
@MainActor
final class GameSession: ObservableObject, Identifiable {
    let id = UUID()
    #if DEBUG
    let debugROMURL: URL
    #endif
    let game: GameEntry
    let companion: CompanionHostModel
    private(set) var saves: SaveManager?
    private(set) var clockSave: SaveManager?
    private(set) var states: StateManager?
    private var diagnosticURL: URL?
    var latestDiagnosticReport = ""
    private var history: SaveHistory?
    private(set) var loaded = false
    private(set) var status = "Starting emulator…"
    private(set) var warning: String?
    init(game: GameEntry, rom: URL, directories: StorageDirectories, coreHash: String, companion: CompanionHostModel) async throws {
        self.companion = companion
        self.game = game
        diagnosticURL = directories.saves.deletingLastPathComponent().appendingPathComponent("last-game-report.txt")
        #if DEBUG
        self.debugROMURL = rom
        #endif
        guard game.core == game.system.coreIdentifier else { throw LibraryError.invalid("Unsupported emulator core.") }
        let is3DS = game.system == .nintendo3DS
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-DSTVDustTrialDefaults") {
            UserDefaults.standard.set(true, forKey: "graphics.ds.dustGPUCore")
            UserDefaults.standard.set(true, forKey: "graphics.ds.dustOutputLimit")
            UserDefaults.standard.set(4, forKey: "graphics.ds.resolution")
            UserDefaults.standard.set(30, forKey: "graphics.ds.presentationRate")
        }
        #endif
        GamePreferences.begin(game.id)
        var preferences = FrontendPreferences.read(from: .standard)
        #if DEBUG
        // Test the renderer without writing a renderer preference into a game profile.
        if ProcessInfo.processInfo.arguments.contains("-DSTVNativeMetal") { preferences.threeDSRenderer = "metal" }
        if ProcessInfo.processInfo.arguments.contains("-DSTVNativeMetalHybrid") { preferences.threeDSRenderer = "mixed" }
        if ProcessInfo.processInfo.arguments.contains("-DSTVMetalSurfaceCache") { preferences.threeDSMetalSurfaceCache = true }
        if ProcessInfo.processInfo.arguments.contains("-DSTVMetalProfile") {
            dstv_set_metal_profiling(1)
        }
        #endif
        if is3DS {
            dstv_set_metal_surface_cache(preferences.threeDSMetalSurfaceCache ? 1 : 0)
            #if DEBUG
            print("3DS experiment configuration: renderer=\(preferences.threeDSRenderer), requested_resolution=\(preferences.threeDSResolution), output=\(preferences.threeDSPresentationRate), surface_cache=\(preferences.threeDSMetalSurfaceCache)")
            #endif
        }
        let dustDS = game.system == .nintendoDS && preferences.dsDustGPUCore
        var scaledDS = game.system == .nintendoDS && (preferences.dsHighResolutionCore || dustDS)
        #if DEBUG
        scaledDS = scaledDS || (game.system == .nintendoDS && ProcessInfo.processInfo.arguments.contains("-DSTVSmokeDSResolution"))
        #endif
        let coreURL = Bundle.main.bundleURL.appendingPathComponent("Frameworks/\(preferences.threeDSRenderer == "vulkan" ? "azahar" : "azahar_metal")_libretro.dylib")
        let dsCoreURL = Bundle.main.bundleURL.appendingPathComponent("Frameworks/\(dustDS ? "dust" : "desmume")_libretro.dylib")
        dstv_set_ds_output_limit(preferences.dsDustOutputLimit ? 4 : 8)
        dstv_set_ds_gpu_renderer(preferences.dsGPURenderer ? 1 : 0)
        let single = !game.system.dualScreen
        let singleCoreURL = Bundle.main.bundleURL.appendingPathComponent("Frameworks/\(game.system.dynamicCore ?? "mgba")_libretro.dylib")
        let rendererMode: Int32 = preferences.threeDSRenderer == "mixed" ? 2 : (preferences.threeDSRenderer == "metal" ? 1 : 0)
        let selected = single ? singleCoreURL.path.withCString { dstv_select_core($0, 0) } : (is3DS ? coreURL.path.withCString { dstv_select_core($0, rendererMode) } :
            (scaledDS ? dsCoreURL.path.withCString { dstv_select_core($0, 0) } : dstv_select_core(nil, 0)))
        guard selected == 1 else { throw LibraryError.invalid("Could not open this system’s emulator core.") }
        let nativeSaves = directories.saves.appendingPathComponent(single ? game.system.saveCore : (is3DS ? "3DS" : (dustDS ? "Dust" : "DeSmuME"))).appendingPathComponent(game.id)
        if is3DS || scaledDS || single { try FileManager.default.createDirectory(at: nativeSaves, withIntermediateDirectories: true) }
        let saveDirectory = is3DS || scaledDS || single ? nativeSaves : directories.saves
        let historyRoot = directories.saves.deletingLastPathComponent().appendingPathComponent("SaveHistory").appendingPathComponent(game.id).appendingPathComponent(is3DS ? "3DS" : (single ? game.system.saveCore : (scaledDS ? (dustDS ? "Dust" : "DeSmuME") : "melonDS")))
        let saveHistory = SaveHistory(source: saveDirectory, destination: historyRoot, filePrefix: is3DS || scaledDS || single ? nil : game.id)
        history = saveHistory
        await withCheckedContinuation { continuation in saveHistory.enqueueCapture { continuation.resume() } }
        guard FileManager.default.fileExists(atPath: rom.path) else { throw LibraryError.invalid("This game needs to be imported again.") }
        let systemDirectory = game.system == .psp ? Bundle.main.bundleURL : directories.system
        let ready = systemDirectory.path.withCString { system in
            saveDirectory.path.withCString { saves in dstv_set_directories(system, saves) }
        }
        guard ready == 1 else { throw LibraryError.invalid("Could not configure emulator storage.") }
        dstv_set_3ds_resolution(UInt32(FrontendPreferences.read(from: .standard).threeDSResolution))
        dstv_set_ds_resolution(UInt32(preferences.dsAutomaticResolution && !dustDS ? min(3, preferences.dsResolution) : preferences.dsResolution))
        dstv_set_ds_presentation_rate(UInt32(preferences.dsPresentationRate))
        dstv_set_psp_options(UInt32(preferences.pspResolution), UInt32(["Auto", "Nearest", "Linear"].firstIndex(of: preferences.pspFiltering) ?? 0), UInt32(["disabled", "2x", "4x", "8x", "16x"].firstIndex(of: preferences.pspAnisotropic) ?? 0))
        let result: Int32
        if is3DS {
            // MoltenVK restores/compiles cached shaders inside retro_load_game.
            // Never hold a scene-update callback while waiting on the compiler.
            let path = rom.path
            result = await Task.detached(priority: .userInitiated) {
                _ = dstv_initialise_core()
                return path.withCString { dstv_load_rom($0) }
            }.value
        } else {
            _ = dstv_initialise_core()
            result = rom.path.withCString { dstv_load_rom($0) }
        }
        guard result == 1 else {
            dstv_deinitialise_core()
            throw LibraryError.invalid(dustDS ? "The experimental Dust core could not load this game. Turn off Dust GPU Core in DS Settings to try the other DS core." : "Could not load this game (\(result)).")
        }
        loaded = true; status = game.title
        if single && game.system != .psp && dstv_memory_size(1) > 0 {
            clockSave = try? SaveManager(romID: game.id + "-rtc", directory: nativeSaves, temporary: directories.usesTemporaryFallback, memoryRegion: 1)
        }
        if !is3DS && !scaledDS && game.system != .psp {
            do {
                saves = try SaveManager(romID: game.id, directory: single ? nativeSaves : directories.saves, temporary: directories.usesTemporaryFallback)
            } catch { warning = "Save setup failed; automatic saves unavailable." }
        }
        if !is3DS && !scaledDS { states = StateManager(directory: directories.saves.deletingLastPathComponent().appendingPathComponent("States").appendingPathComponent(single ? game.system.saveCore : ""), romID: game.id, coreID: single ? (try? SaveDisk.identity(for: singleCoreURL)) ?? game.core.rawValue : coreHash) }
    }
    func stop() {
        guard loaded else { return }
        // Root will not dismiss while a state callback could restore into another game.
        saves?.flush(); clockSave?.flush(); states?.flush()
        if let diagnosticURL, !latestDiagnosticReport.isEmpty {
            try? Data(latestDiagnosticReport.utf8).write(to: diagnosticURL, options: .atomic)
        }
        companion.endGame()
        dstv_set_touch(0, 0, 0); dstv_set_companion_buttons(0)
        dstv_set_audio_enabled(0); dstv_set_buttons(0)
        dstv_deinitialise_core()
        history?.enqueueCapture()
        loaded = false
        GamePreferences.end()
    }
}
