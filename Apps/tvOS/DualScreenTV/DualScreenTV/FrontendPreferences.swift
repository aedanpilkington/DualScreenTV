import Foundation
import CoreGraphics

nonisolated enum DSScreen: String, CaseIterable { case top, bottom }

nonisolated enum ScreenDisplayMode: String, CaseIterable {
    case original, overscan, fill, stretch

    func imageSize(in viewport: CGSize, zoomPercent: Double, source: CGSize = CGSize(width: 256, height: 192)) -> CGSize {
        guard viewport.width > 0, viewport.height > 0 else { return .zero }
        if self == .stretch { return viewport }
        let fit = min(viewport.width / source.width, viewport.height / source.height)
        let fill = max(viewport.width / source.width, viewport.height / source.height)
        let zoom = zoomPercent.isFinite ? min(25, max(0, zoomPercent)) : 10
        let scale = self == .fill ? fill : fit * (self == .overscan ? 1 + zoom / 100 : 1)
        return CGSize(width: source.width * scale, height: source.height * scale)
    }
}

nonisolated enum ImageEnhancement: String, CaseIterable {
    case off, two = "2", four = "4"
    var factor: Int { Int(rawValue) ?? 1 }
}

nonisolated enum ImageFiltering: String, CaseIterable { case nearest, linear }

nonisolated enum InputBinding: String, CaseIterable {
    case none, a, b, x, y, l, r, zl, zr, start, select
    case fastForward, pause, reset, saveState, loadState, switchScreen
    var mask: UInt16 {
        switch self {
        case .none, .fastForward, .pause, .reset, .saveState, .loadState, .switchScreen: 0
        case .a: 1 << 8
        case .b: 1 << 0
        case .x: 1 << 9
        case .y: 1 << 1
        case .l: 1 << 10
        case .r: 1 << 11
        case .zl: 1 << 12
        case .zr: 1 << 13
        case .start: 1 << 3
        case .select: 1 << 2
        }
    }
}

nonisolated extension InputBinding {
    var actionMask: UInt8 {
        switch self {
        case .fastForward: 1
        case .pause: 2
        case .reset: 4
        case .saveState: 8
        case .loadState: 16
        case .switchScreen: 32
        default: 0
        }
    }
}

nonisolated enum RemoteButton: String, CaseIterable {
    case center, menu, playPause, rewind, fastForward
    var key: String { "remote." + rawValue }
    var defaultMapping: InputBinding {
        switch self {
        case .center: .a
        case .menu: .start
        case .playPause: .b
        case .rewind: .select
        case .fastForward: .x
        }
    }
}

// Face buttons use physical positions so one layout works across controller labels.
nonisolated enum GamepadButton: String, CaseIterable {
    case south, east, west, north, leftShoulder, rightShoulder
    case leftTrigger, rightTrigger, leftStick, rightStick, menu, options
    var key: String { "gamepad." + rawValue }
    func defaultMapping(shapeLabels: Bool) -> InputBinding {
        switch self {
        case .south: .a
        case .east: .b
        case .west: shapeLabels ? .y : .x
        case .north: shapeLabels ? .x : .y
        case .leftShoulder: .l
        case .rightShoulder: .r
        case .menu: .start
        case .options: .select
        case .leftTrigger, .rightTrigger, .leftStick, .rightStick: .none
        }
    }
}

nonisolated struct ScreenPresentation: Equatable {
    var mode: ScreenDisplayMode = .original
    var zoom = 10.0
    var filtering: ImageFiltering = .nearest
    var enhancement: ImageEnhancement = .off
    var integerScale = false
    func imageSize(in viewport: CGSize, source: CGSize = CGSize(width: 256, height: 192)) -> CGSize {
        if integerScale && mode == .original && viewport.width >= source.width && viewport.height >= source.height {
            let scale = floor(min(viewport.width / source.width, viewport.height / source.height))
            return CGSize(width: source.width * scale, height: source.height * scale)
        }
        return mode.imageSize(in: viewport, zoomPercent: zoom, source: source)
    }
}

nonisolated struct FrontendPreferences: Equatable {
    // Explicitly top-screen-only. A bottom screen must use its own preference.
    static let topModeKey = "display.top.mode"
    static let topZoomKey = "display.top.overscanPercent"
    static let mediaButtonsKey = "remote.extraMediaButtons"
    var screen: DSScreen = .top
    var gamepadScreenShortcut: GamepadScreenShortcut = .triggers
    var remoteScreenShortcut = true
    var bottomPresentation = ScreenPresentation()
    var threeDSPresentationRate = 60
    var threeDSRenderer = "vulkan"
    var threeDSMetalSurfaceCache = false
    var threeDSResolution = 1
    var pspResolution = 1
    var pspFiltering = "Auto"
    var pspAnisotropic = "disabled"
    var gbDisplayMode: ScreenDisplayMode = .original
    var gbOverscanPercent: Double = 10
    var gbIntegerScale = true
    var gbSmoothing = false
    var gbColourCorrection = false
    var gbLCD = false
    var dsHighResolutionCore = false
    var dsDustGPUCore = false
    var dsDustOutputLimit = true
    var dsResolution = 2
    var dsAutomaticResolution = true
    var dsPresentationRate = 60
    var dsGPURenderer = true
    var normalSpeed = 1.0
    var fastForwardSpeed = 2.0 // Zero means bounded, best-effort Unlimited.
    var toggleFastForward = false
    var stateSlot = 1
    var enhancement: ImageEnhancement = .off
    var filtering: ImageFiltering = .nearest
    var integerScale = false
    var volume = 100
    var muted = false
    var mixWithOtherAudio = true
    var showFPS = false
    var showFrames = false
    var showPerformance = false
    var mediaButtonsEnabled = false
    var topMode: ScreenDisplayMode = .original
    var topOverscanPercent: Double = 10
    var remoteMappings: [RemoteButton: InputBinding] = [:]
    var gamepadMappings: [GamepadButton: InputBinding] = [:]

    static var registeredDefaults: [String: Any] {
        var values: [String: Any] = [topModeKey: "original", topZoomKey: 10, mediaButtonsKey: false]
        values.merge(["graphics.psp.resolution": 1, "graphics.psp.filtering": "Auto", "graphics.psp.anisotropic": "disabled", "display.gb.mode": "original", "display.gb.overscanPercent": 10, "graphics.gb.integerScale": true, "graphics.gb.smoothing": false, "graphics.gb.colourCorrection": false, "graphics.gb.lcd": false]) { _, new in new }
        values.merge(["backup.enabled": true, "backup.forgetDevices": false, "graphics.ds.highResolutionCore": false, "graphics.ds.dustGPUCore": false, "graphics.ds.dustOutputLimit": true, "graphics.ds.gpuRenderer": true, "graphics.ds.resolution": 2, "graphics.ds.automaticResolution": true, "graphics.ds.presentationRate": 60, "graphics.3ds.renderer": "vulkan", "graphics.3ds.metalSurfaceCache": false, "graphics.3ds.presentationRate": 60, "graphics.3ds.resolution": 1, "emulation.speed": 1.0, "emulation.fastForwardSpeed": 2.0,
                      "emulation.toggleFastForward": false, "states.slot": 1]) { _, new in new }
        values.merge(["display.top.enhancement": "off", "display.top.filtering": "nearest", "display.top.integerScale": false,
                      "audio.volume": 100, "audio.mute": false, "audio.mixWithOthers": true, "debug.fps": false,
                      "debug.frames": false, "debug.performance": false]) { _, new in new }
        values.merge(["display.screen": "top", "controls.screenShortcut": "triggers",
                      "remote.screenShortcut": true, "display.bottom.mode": "original",
                      "display.bottom.overscanPercent": 10, "display.bottom.filtering": "nearest",
                      "display.bottom.enhancement": "off", "display.bottom.integerScale": false]) { _, new in new }
        for button in RemoteButton.allCases { values[button.key] = button.defaultMapping.rawValue }
        for button in GamepadButton.allCases { values[button.key] = "default" }
        return values
    }

    static func read(from defaults: UserDefaults) -> Self {
        var result = Self()
        result.dsAutomaticResolution = defaults.bool(forKey: "graphics.ds.automaticResolution")
        result.dsPresentationRate = defaults.integer(forKey: "graphics.ds.presentationRate") == 30 ? 30 : 60
        let renderer = defaults.string(forKey: "graphics.3ds.renderer")
        switch renderer {
        case let value? where ["metal", "mixed", "vulkan"].contains(value):
            result.threeDSRenderer = value
        default:
            result.threeDSRenderer = "vulkan"
        }
        result.threeDSMetalSurfaceCache = defaults.bool(forKey: "graphics.3ds.metalSurfaceCache")
        result.threeDSPresentationRate = defaults.integer(forKey: "graphics.3ds.presentationRate") == 30 ? 30 : 60
        let resolution = defaults.integer(forKey: "graphics.3ds.resolution")
        result.threeDSResolution = (1...4).contains(resolution) ? resolution : 1
        result.dsGPURenderer = defaults.bool(forKey: "graphics.ds.gpuRenderer")
        result.dsDustGPUCore = defaults.bool(forKey: "graphics.ds.dustGPUCore")
        result.dsDustOutputLimit = defaults.bool(forKey: "graphics.ds.dustOutputLimit")
        result.dsHighResolutionCore = defaults.bool(forKey: "graphics.ds.highResolutionCore")
        let dsResolution = defaults.integer(forKey: "graphics.ds.resolution")
        result.dsResolution = (1...8).contains(dsResolution) ? dsResolution : 2
        let args = ProcessInfo.processInfo.arguments
        #if DEBUG
        if args.contains("-DSTVMetalSurfaceCache") { result.threeDSMetalSurfaceCache = true }
        if args.contains("-DSTVMetalBenchmark60") { result.threeDSPresentationRate = 60 }
        if let index = args.firstIndex(of: "-DSTVSmokeResolution"), index + 1 < args.count,
           let value = Int(args[index + 1]), (1...4).contains(value) { result.threeDSResolution = value }
        #endif
        result.pspResolution = min(4, max(1, (defaults.object(forKey: "graphics.psp.resolution") as? NSNumber)?.intValue ?? 1))
        #if DEBUG
        if args.contains("-DSTVMetalSurfaceCache") { result.threeDSMetalSurfaceCache = true }
        if args.contains("-DSTVMetalBenchmark60") { result.threeDSPresentationRate = 60 }
        if let index = args.firstIndex(of: "-DSTVSmokePSPResolution"), index + 1 < args.count,
           let value = Int(args[index + 1]), (1...4).contains(value) { result.pspResolution = value }
        #endif
        let pspFiltering = defaults.string(forKey: "graphics.psp.filtering") ?? "Auto"
        result.pspFiltering = ["Auto", "Nearest", "Linear"].contains(pspFiltering) ? pspFiltering : "Auto"
        let anisotropic = defaults.string(forKey: "graphics.psp.anisotropic") ?? "disabled"
        result.pspAnisotropic = ["disabled", "2x", "4x", "8x", "16x"].contains(anisotropic) ? anisotropic : "disabled"
        result.gbDisplayMode = ScreenDisplayMode(rawValue: defaults.string(forKey: "display.gb.mode") ?? "") ?? .original
        let gbZoom = (defaults.object(forKey: "display.gb.overscanPercent") as? NSNumber)?.doubleValue ?? 10
        result.gbOverscanPercent = gbZoom.isFinite ? min(25, max(0, gbZoom)) : 10
        result.gbIntegerScale = defaults.object(forKey: "graphics.gb.integerScale") as? Bool ?? true
        result.gbSmoothing = defaults.bool(forKey: "graphics.gb.smoothing")
        result.gbColourCorrection = defaults.bool(forKey: "graphics.gb.colourCorrection")
        result.gbLCD = defaults.bool(forKey: "graphics.gb.lcd")
        result.screen = DSScreen(rawValue: defaults.string(forKey: "display.screen") ?? "") ?? .top
        result.gamepadScreenShortcut = GamepadScreenShortcut(rawValue: defaults.string(forKey: "controls.screenShortcut") ?? "") ?? .triggers
        result.remoteScreenShortcut = (defaults.object(forKey: "remote.screenShortcut") as? NSNumber)?.boolValue ?? true
        result.bottomPresentation.mode = ScreenDisplayMode(rawValue: defaults.string(forKey: "display.bottom.mode") ?? "") ?? .original
        let bottomZoom = (defaults.object(forKey: "display.bottom.overscanPercent") as? NSNumber)?.doubleValue ?? 10
        result.bottomPresentation.zoom = bottomZoom.isFinite ? min(25, max(0, bottomZoom)) : 10
        result.bottomPresentation.filtering = ImageFiltering(rawValue: defaults.string(forKey: "display.bottom.filtering") ?? "") ?? .nearest
        result.bottomPresentation.enhancement = ImageEnhancement(rawValue: defaults.string(forKey: "display.bottom.enhancement") ?? "") ?? .off
        result.bottomPresentation.integerScale = defaults.bool(forKey: "display.bottom.integerScale")
        let speed = (defaults.object(forKey: "emulation.speed") as? NSNumber)?.doubleValue ?? 1
        result.normalSpeed = [0.5, 1, 1.5, 2, 3, 4].contains(speed) ? speed : 1
        let fast = (defaults.object(forKey: "emulation.fastForwardSpeed") as? NSNumber)?.doubleValue ?? 2
        result.fastForwardSpeed = [0, 2, 3, 4].contains(fast) ? fast : 2
        result.toggleFastForward = defaults.bool(forKey: "emulation.toggleFastForward")
        result.stateSlot = min(10, max(1, (defaults.object(forKey: "states.slot") as? NSNumber)?.intValue ?? 1))
        result.enhancement = ImageEnhancement(rawValue: defaults.string(forKey: "display.top.enhancement") ?? "") ?? .off
        #if DEBUG
        // Transient device benchmark; never writes the user's preference.
        if let index = args.firstIndex(of: "-DSTVSmokeEnhancement"), index + 1 < args.count,
           let enhancement = ImageEnhancement(rawValue: args[index + 1]) { result.enhancement = enhancement }
        #endif
        result.filtering = ImageFiltering(rawValue: defaults.string(forKey: "display.top.filtering") ?? "") ?? .nearest
        result.integerScale = defaults.bool(forKey: "display.top.integerScale")
        result.volume = min(100, max(0, (defaults.object(forKey: "audio.volume") as? NSNumber)?.intValue ?? 100))
        result.muted = defaults.bool(forKey: "audio.mute")
        result.mixWithOtherAudio = (defaults.object(forKey: "audio.mixWithOthers") as? Bool) ?? true
        result.showFPS = defaults.bool(forKey: "debug.fps")
        result.showFrames = defaults.bool(forKey: "debug.frames")
        result.showPerformance = defaults.bool(forKey: "debug.performance")
        result.mediaButtonsEnabled = defaults.bool(forKey: mediaButtonsKey)
        result.topMode = ScreenDisplayMode(rawValue: defaults.string(forKey: topModeKey) ?? "") ?? .original
        let zoom = defaults.object(forKey: topZoomKey) as? NSNumber
        result.topOverscanPercent = min(25, max(0, zoom?.doubleValue ?? 10))
        for button in RemoteButton.allCases {
            result.remoteMappings[button] = InputBinding(rawValue: defaults.string(forKey: button.key) ?? "") ?? button.defaultMapping
        }
        for button in GamepadButton.allCases {
            result.gamepadMappings[button] = InputBinding(rawValue: defaults.string(forKey: button.key) ?? "")
        }
        return result
    }

    func presentation(for screen: DSScreen) -> ScreenPresentation {
        screen == .bottom ? bottomPresentation : ScreenPresentation(mode: topMode, zoom: topOverscanPercent,
            filtering: filtering, enhancement: enhancement, integerScale: integerScale)
    }
    func topImageSize(in viewport: CGSize) -> CGSize { presentation(for: .top).imageSize(in: viewport) }

    func gamepadBinding(for button: GamepadButton, shapeLabels: Bool) -> InputBinding {
        gamepadMappings[button] ?? button.defaultMapping(shapeLabels: shapeLabels)
    }

    func gamepadMask(pressed: [GamepadButton], shapeLabels: Bool) -> UInt16 {
        pressed.reduce(0) { mask, button in
            mask | (gamepadMappings[button] ?? button.defaultMapping(shapeLabels: shapeLabels)).mask
        }
    }

    func mapping(for button: RemoteButton) -> InputBinding {
        remoteMappings[button] ?? button.defaultMapping
    }
}

// Native media commands may only supply a tap, rather than key-down/up. Latch
// taps for three frames so short events reach the core without stuck buttons.
nonisolated struct RemoteButtonPulses {
    private var remaining: [RemoteButton: Int] = [:]
    mutating func press(_ button: RemoteButton) { remaining[button] = 3 }
    mutating func clear() { remaining.removeAll() }
    mutating func nextButtons() -> Set<RemoteButton> {
        var buttons = Set<RemoteButton>()
        for button in RemoteButton.allCases {
            let frames = remaining[button, default: 0]
            if frames > 0 {
                buttons.insert(button)
                remaining[button] = frames - 1
            }
        }
        return buttons
    }
    mutating func nextBindings(preferences: FrontendPreferences) -> Set<InputBinding> {
        Set(nextButtons().map { preferences.mapping(for: $0) })
    }
    mutating func nextMask(preferences: FrontendPreferences) -> UInt16 {
        nextBindings(preferences: preferences).reduce(0) { $0 | $1.mask }
    }
}
